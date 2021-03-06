paths.dofile('layers/Residual.lua')

local function hourglass(n, f, inp)
    -- Upper branch
    local up1 = inp
    for i = 1,opt.nModules do up1 = Residual(f,f)(up1) end

    -- Lower branch
    local low1 = nnlib.SpatialMaxPooling(2,2,2,2)(inp)

    for i = 1,opt.nModules do low1 = Residual(f,f)(low1) end
    local low2

    local features
    if n > 1 then
        local sub = hourglass(n-1,f,low1)
        low2 = sub.hg
        features = sub.feat
    else
        low2 = low1
        for i = 1,opt.nModules do low2 = Residual(f,f)(low2) end
        features = low2
    end

    local low3 = low2
    for i = 1,opt.nModules do low3 = Residual(f,f)(low3) end
    local up2 = nn.SpatialUpSamplingNearest(2)(low3)

    -- Bring two branches together
    return { hg = nn.CAddTable()({up1,up2}), feat = features }
end

local function lin(numIn,numOut,inp)
    -- Apply 1x1 convolution, stride 1, no padding
    local l = nnlib.SpatialConvolution(numIn,numOut,1,1,1,1,0,0)(inp)
    return nnlib.ReLU(true)(nn.SpatialBatchNormalization(numOut)(l))
end

function createModel()

    local inp = nn.Identity()()

    -- Initial processing of the image
    local cnv1_ = nnlib.SpatialConvolution(3,64,7,7,2,2,3,3)(inp)           -- 128
    local cnv1 = nnlib.ReLU(true)(nn.SpatialBatchNormalization(64)(cnv1_))
    local r1 = Residual(64,128)(cnv1)
    local pool = nnlib.SpatialMaxPooling(2,2,2,2)(r1)                       -- 64
    local r4 = Residual(128,128)(pool)
    local r5 = Residual(128,opt.nFeats)(r4)

    local out = {}
    local inter = r5

    local featureinp

    for i = 1,opt.nStack do
        local sub = hourglass(4,opt.nFeats,inter)
        local hg = sub.hg
        local features = sub.feat

        -- For final hourglass, branch features off
        if i == opt.nStack then featureinp = features end

        -- Residual layers at output resolution
        local ll = hg
        for j = 1,opt.nModules do ll = Residual(opt.nFeats,opt.nFeats)(ll) end
        -- Linear layer to produce first set of predictions
        ll = lin(opt.nFeats,opt.nFeats,ll)

        -- Predicted heatmaps
        local tmpOut = nnlib.SpatialConvolution(opt.nFeats,opt.nOutChannels,1,1,1,1,0,0)(ll)
        table.insert(out,tmpOut)

        -- Add predictions back
        if i < opt.nStack then
            local ll_ = nnlib.SpatialConvolution(opt.nFeats,opt.nFeats,1,1,1,1,0,0)(ll)
            local tmpOut_ = nnlib.SpatialConvolution(opt.nOutChannels,opt.nFeats,1,1,1,1,0,0)(tmpOut)
            inter = nn.CAddTable()({inter, ll_, tmpOut_})
        end
    end

    -- Binary classification branch
    local branchres1 = Residual(opt.nFeats,opt.nFeats)(featureinp)
    local branchres2 = Residual(opt.nFeats,opt.nFeats)(branchres1)
    local branchout = nnlib.Sigmoid()(nnlib.SpatialConvolution(opt.nFeats,1,4,4,1,1,0,0)(branchres2))
    table.insert(out, branchout)

    -- Final model
    local model = nn.gModule({inp}, out)

    return model

end
