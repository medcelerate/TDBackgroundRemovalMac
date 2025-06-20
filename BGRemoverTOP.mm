// InstanceMaskTOP.h

#include "TOP_CPlusPlusBase.hpp"

#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <OpenGL/gl.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
        case OP_PixelFormat::RGBA32Float:
            format = kCIFormatRGBAf;
            bytesPerRow = width * 16;
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

    
    
    
    // Lock the pixel buffer to access its data
    
    CVPixelBufferLockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
    auto g = CVPixelBufferGetDataSize(maskPB);
    float*  srcF      = (float*)CVPixelBufferGetBaseAddress(maskPB);
    size_t  strideF  = CVPixelBufferGetBytesPerRow(maskPB) / sizeof(float);
    size_t     W       = CVPixelBufferGetWidth(maskPB);
    size_t     H       = CVPixelBufferGetHeight(maskPB);
    if (!srcF || W != width || H != height) {
        CVPixelBufferUnlockBaseAddress(maskPB, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(maskPB);
        return;
    }
        
    

    TD::OP_SmartRef<TD::TOP_Buffer> buf = myContext->createOutputBuffer(downRes->size, TD::TOP_BufferFlags::None, nullptr);
    

    uint8_t* dst    = (uint8_t*)buf->data;
    size_t   dstRow = W * 4;

    switch (opts.pixelFormat) {

      // ——————————————————————————————————————
      case OP_PixelFormat::BGRA8Fixed:
      case OP_PixelFormat::RGBA8Fixed: {
        size_t dstRow = W * 4;                        // 4 bytes/pixel
        // write U8 RGBA
        for (int y = 0; y < H; ++y) {
          float*   sRow = srcF  + y*strideF;
          uint8_t* dRow = dst + y*dstRow;
          for (int x = 0; x < W; ++x) {
            float   f = sRow[x];                      // [0..1]
            uint8_t m = (f > 0.5f ? 255 : 0);          // hard threshold
            dRow[4*x + 0] = m;                        // B or R
            dRow[4*x + 1] = m;                        // G
            dRow[4*x + 2] = m;                        // R or B
            dRow[4*x + 3] = 255;                      // A
          }
        }
        break;
      }

      // ——————————————————————————————————————
      case OP_PixelFormat::RGBA16Fixed: {
        size_t dstRow = W * 8;                        // 8 bytes/pixel
        // write U16 RGBA
        for (int y = 0; y < H; ++y) {
          float*    sRow = srcF + y*strideF;
          uint16_t* dRow = (uint16_t*)(dst + y*dstRow);
          for (int x = 0; x < W; ++x) {
            float    f   = sRow[x];
            uint16_t m16 = (f > 0.5f ? 0xFFFF          // threshold to full
                                    : uint16_t(f*65535.0f));
            dRow[4*x + 0] = m16;
            dRow[4*x + 1] = m16;
            dRow[4*x + 2] = m16;
            dRow[4*x + 3] = 0xFFFF;                   // full alpha
          }
        }
        break;
      }

      // ——————————————————————————————————————
      default: {
        // assume anything else you want as full 32-bit float RGBA
        size_t dstRow = W * 4 * sizeof(float);
        for (int y = 0; y < H; ++y) {
          float* dRow = (float*)(dst + y*dstRow);
          float* sRow = srcF   + y*strideF;
          for (int x = 0; x < W; ++x) {
            float v = sRow[x];      // raw probability [0..1]
            // if you want a hard cut, uncomment:
            // v = (v > 0.5f ? 1.0f : 0.0f);
            dRow[4*x + 0] = v;
            dRow[4*x + 1] = v;
            dRow[4*x + 2] = v;
            dRow[4*x + 3] = 1.0f;
          }
        }
        // your SDK’s float‐RGBA format:
        break;
      }
    }
    
    TD::TOP_UploadInfo info;
    info.textureDesc = top->textureDesc;
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

