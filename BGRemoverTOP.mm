// InstanceMaskTOP.h

#include "TOP_CPlusPlusBase.hpp"

#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <OpenGL/gl.h>

using namespace TD;

class InstanceMaskTOP : public TOP_CPlusPlusBase {
public:
    InstanceMaskTOP(const OP_NodeInfo* info, TOP_Context* context);
    virtual ~InstanceMaskTOP();

    virtual void getGeneralInfo(TOP_GeneralInfo* ginfo, const OP_Inputs* inputs, void* reserved1) override;
    virtual void execute(TOP_Output*, const OP_Inputs*, void* reserved) override;
    virtual void setupParameters(OP_ParameterManager* manager, void* reserved1) override;
    virtual void pulsePressed(const char* name, void* reserved1) override;
private:
    TOP_Context* myContext;
};

extern "C" {

DLLEXPORT void FillTOPPluginInfo(TOP_PluginInfo* info) {
    info->apiVersion = TOPCPlusPlusAPIVersion;
    info->executeMode = TOP_ExecuteMode::CPUMem; // using CPU-side buffers
    
    auto& custom = info->customOPInfo;
    custom.opType->setString("InstanceMaskTOP");
    custom.opLabel->setString("Instance Mask TOP");
    custom.opIcon->setString("BGM");
    custom.authorName->setString("Evan Clark");
    custom.authorEmail->setString("you@example.com");
    custom.minInputs = 1;
    custom.maxInputs = 1;
}

DLLEXPORT TOP_CPlusPlusBase* CreateTOPInstance(const OP_NodeInfo* info, TOP_Context* context) {
    return new InstanceMaskTOP(info, context);
}

DLLEXPORT void DestroyTOPInstance(TOP_CPlusPlusBase* instance, TOP_Context *context) {
    delete (InstanceMaskTOP*)instance;
}
}


InstanceMaskTOP::InstanceMaskTOP(const OP_NodeInfo* info, TOP_Context* context) {
    myContext = context;
}
InstanceMaskTOP::~InstanceMaskTOP() {}

void InstanceMaskTOP::getGeneralInfo(TOP_GeneralInfo* ginfo, const OP_Inputs* /*inputs*/, void* /*reserved1*/) {
    // we cook every frame to update masks in real time
    ginfo->cookEveryFrame = true;
    // output includes an alpha channel
}

void InstanceMaskTOP::execute(TOP_Output* output, const OP_Inputs* inputs, void* reserved) {
    // Acquire CPU buffer of the input TOP
    const OP_TOPInput*    top = inputs->getInputTOP(0);

        if (!top)
            return;
    int height = top->textureDesc.height;
    int width = top->textureDesc.width;
    
    OP_TOPInputDownloadOptions    opts;
    opts.pixelFormat = top->textureDesc.pixelFormat;

    
    OP_SmartRef<OP_TOPDownloadResult> downRes = top->downloadTexture(opts,nullptr);
    // Wrap input pixels in a CIImage
    size_t bytesPerRow = 0;
    CIFormat format = kCIFormatRGBA8;
    switch(opts.pixelFormat) {
        case OP_PixelFormat::BGRA8Fixed:
            format = kCIFormatBGRA8;
            bytesPerRow = width * 4;
            break;
        case OP_PixelFormat::RGBA8Fixed:
            format = kCIFormatRGBA8;
            bytesPerRow = width * 4;
            break;
        case OP_PixelFormat::RGBA16Fixed:
            format = kCIFormatRGBA16;
            bytesPerRow = width * 8;
            break;
        default:
            return;
    }
    CIImage* ciImage = [CIImage imageWithBitmapData:[NSData dataWithBytes:downRes->getData() length:bytesPerRow * height]
                                          bytesPerRow:bytesPerRow
                                                size:CGSizeMake(width, height)
                                          format:format
                                      colorSpace:CGColorSpaceCreateDeviceRGB()];

    
    
    VNGenerateForegroundInstanceMaskRequest* fgRequest = [VNGenerateForegroundInstanceMaskRequest new];
    fgRequest.revision = VNGenerateForegroundInstanceMaskRequestRevision1;
    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCIImage:ciImage options:@{}];

    NSError* error = nil;
    [handler performRequests:@[fgRequest] error:&error];
    if (error) {
        // on error, just copy input to output
        return;
    }

    // Retrieve the mask pixel buffer
    if (!fgRequest.results) {
        return;
    }
    auto res = fgRequest.results.firstObject;
    //Refine
    
    CVPixelBufferRef maskPB = [res generateScaledMaskForImageForInstances:res.allInstances fromRequestHandler: handler error: &error];
    if (error) {
        return;
    }
    CVPixelBufferLockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
    uint8_t* maskBase = (uint8_t*)CVPixelBufferGetBaseAddress(maskPB);
    if(!maskBase) {
        return;
    }

    TD::OP_SmartRef<TD::TOP_Buffer> buf = myContext->createOutputBuffer(downRes->size, TD::TOP_BufferFlags::None, nullptr);
    
    
    // Copy the mask to the output buffer
    
    uint8_t* dst = (uint8_t*)buf->data;
    for (int y = 0; y < buf->size; y+=4) {
        dst[y]     = maskBase[y]  ; // R
        dst[y + 1] = maskBase[y+1]; // G
        dst[y + 2] = maskBase[y+2]; // B
        dst[y + 3] = 255; // A from mask
    }
        
    
    TD::TOP_UploadInfo info;
    info.textureDesc = downRes->textureDesc;
    info.colorBufferIndex = 0;
    
    output->uploadBuffer(&buf, info, nullptr);

    CVPixelBufferUnlockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferRelease(maskPB);

}

void InstanceMaskTOP::setupParameters(OP_ParameterManager* manager, void* /*reserved1*/) {
    // Example toggle to switch between fast/accurate
   // OP_ParAppendResult res = manager->appendToggle("fastSegmentation", "Fast Segmentation", true);
}

void InstanceMaskTOP::pulsePressed(const char* /*name*/, void* /*reserved1*/) {}

