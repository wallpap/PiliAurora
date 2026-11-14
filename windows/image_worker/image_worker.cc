// Windows 区域解码：WIC/libwebp 直接读取有界区域；持续 worker 保留源，退出释放
// decoder 工作区。
#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <io.h>
#include <iostream>
#include <psapi.h>
#include <sstream>
#include <vector>
#include <webp/decode.h>
#include <wincodec.h>
#include <wrl/client.h>
using Microsoft::WRL::ComPtr;
void Check(HRESULT hr) {
  if (FAILED(hr))
    throw hr;
}
PROCESS_MEMORY_COUNTERS_EX Memory() {
  PROCESS_MEMORY_COUNTERS_EX p{};
  p.cb = sizeof(p);
  GetProcessMemoryInfo(GetCurrentProcess(),
                       reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&p),
                       sizeof(p));
  return p;
}
uint32_t U32(const uint8_t *p) {
  return p[0] | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}
struct SourceFile {
  HANDLE file = INVALID_HANDLE_VALUE;
  HANDLE mapping = nullptr;
  const uint8_t *pixels = nullptr;
  ~SourceFile() {
    if (pixels)
      UnmapViewOfFile(pixels);
    if (mapping)
      CloseHandle(mapping);
    if (file != INVALID_HANDLE_VALUE)
      CloseHandle(file);
  }
};
struct ComApartment {
  ComApartment() { Check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); }
  ~ComApartment() { CoUninitialize(); }
};
int wmain(int argc, wchar_t **argv) {
  const bool reference = argc == 4 && std::wstring(argv[3]) == L"reference";
  const bool pipe = argc == 4 && std::wstring(argv[3]) == L"pipe";
  if (argc != 3 && !reference && !pipe)
    return 2;
  if (pipe && _setmode(_fileno(stdout), _O_BINARY) == -1)
    return 2;
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
               SEM_NOOPENFILEERRORBOX);
  try {
    ComApartment apartment;
    ComPtr<IWICImagingFactory> factory;
    Check(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                           CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)));
    SourceFile handles;
    HANDLE file = handles.file =
        CreateFileW(argv[1], GENERIC_READ, FILE_SHARE_READ, nullptr,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
      throw HRESULT_FROM_WIN32(GetLastError());
    LARGE_INTEGER length{};
    if (!GetFileSizeEx(file, &length) || length.QuadPart <= 0)
      throw E_FAIL;
    HANDLE mapping = handles.mapping =
        CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
    if (!mapping)
      throw E_FAIL;
    const auto *encoded = handles.pixels = static_cast<const uint8_t *>(
        MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
    if (!encoded)
      throw E_FAIL;
    const bool webp = length.QuadPart >= 12 && !memcmp(encoded, "RIFF", 4) &&
                      !memcmp(encoded + 8, "WEBP", 4);
    UINT width = 0, height = 0, frames = 0;
    int orientation = 1;
    bool hasICC = false;
    bool supported = webp;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICBitmapSource> source;
    ComPtr<IWICColorContext> inputColor, outputColor;
    WebPBitstreamFeatures features{};
    if (webp) {
      if (WebPGetFeatures(encoded, static_cast<size_t>(length.QuadPart),
                          &features) != VP8_STATUS_OK)
        throw E_FAIL;
      width = features.width;
      height = features.height;
      frames = features.has_animation ? 2 : 1;
      for (size_t pos = 12; pos + 8 <= static_cast<size_t>(length.QuadPart);) {
        const uint32_t bytes = U32(encoded + pos + 4);
        if (bytes > static_cast<size_t>(length.QuadPart) - pos - 8)
          throw E_INVALIDARG;
        if (!memcmp(encoded + pos, "EXIF", 4))
          orientation = -1; // 不静默忽略未验证的方向。
        if (!memcmp(encoded + pos, "ICCP", 4)) {
          Check(factory->CreateColorContext(&inputColor));
          Check(inputColor->InitializeFromMemory(
              const_cast<BYTE *>(encoded + pos + 8), bytes));
          hasICC = true;
        }
        pos += 8 + bytes + (bytes & 1);
      }
    } else {
      const auto decoderStatus = factory->CreateDecoderFromFilename(
          argv[1], nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder);
      if (FAILED(decoderStatus)) {
        const bool jpegHeader = length.QuadPart >= 3 && encoded[0] == 0xff &&
                                encoded[1] == 0xd8 && encoded[2] == 0xff;
        const bool pngHeader = length.QuadPart >= 8 &&
                               !memcmp(encoded, "\x89PNG\r\n\x1a\n", 8);
        if (!jpegHeader && !pngHeader) {
          // 系统没有此格式的 WIC codec；交还 Flutter，不把能力缺失当作解码损坏。
          std::cout << "{\"unsupported\":true}" << std::endl;
          return 0;
        }
        Check(decoderStatus);
      }
      GUID format{};
      Check(decoder->GetContainerFormat(&format));
      supported = IsEqualGUID(format, GUID_ContainerFormatJpeg) ||
                  IsEqualGUID(format, GUID_ContainerFormatPng);
      Check(decoder->GetFrameCount(&frames));
      Check(decoder->GetFrame(0, &frame));
      Check(frame->GetSize(&width, &height));
      source = frame;
      ComPtr<IWICMetadataQueryReader> metadata;
      if (SUCCEEDED(frame->GetMetadataQueryReader(&metadata))) {
        for (const auto *query :
             {L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
          PROPVARIANT value;
          PropVariantInit(&value);
          if (SUCCEEDED(metadata->GetMetadataByName(query, &value)) &&
              value.vt == VT_UI2 && value.uiVal > 0)
            orientation = value.uiVal;
          PropVariantClear(&value);
        }
      }
      UINT colors = 0;
      if (SUCCEEDED(frame->GetColorContexts(0, nullptr, &colors)) && colors) {
        if (colors != 1)
          throw E_NOTIMPL;
        Check(factory->CreateColorContext(&inputColor));
        auto *color = inputColor.Get();
        Check(frame->GetColorContexts(1, &color, &colors));
        hasICC = true;
      }
    }
    if (hasICC) {
      Check(factory->CreateColorContext(&outputColor));
      Check(outputColor->InitializeFromExifColorSpace(1));
    }
    std::cout << "{\"ready\":true,\"pid\":" << GetCurrentProcessId()
              << ",\"width\":" << width << ",\"height\":" << height
              << ",\"frames\":" << frames << ",\"orientation\":" << orientation
              << ",\"webp\":" << (webp ? "true" : "false")
              << ",\"supported\":" << (supported ? "true" : "false")
              << ",\"icc\":" << (hasICC ? "true" : "false") << "}" << std::endl;
    if (!supported || frames != 1 || orientation != 1) {
      std::string close;
      std::getline(std::cin, close);
      return 0;
    }
    std::string line;
    while (std::getline(std::cin, line)) {
      if (line == "close")
        break;
      int level, x, y, w, h, index;
      std::istringstream in(line);
      if (!(in >> level >> x >> y >> w >> h >> index) || level < 0 ||
          level > 16 || x < 0 || y < 0 || w <= 0 || h <= 0 || index < 0)
        throw E_INVALIDARG;
      const int factor = 1 << level;
      const UINT sw = (width + factor - 1) / factor,
                 sh = (height + factor - 1) / factor;
      const uint64_t bytes = uint64_t(w) * h * 4;
      if (webp && level == 0 && ((x & 1) || (y & 1)))
        throw E_INVALIDARG;
      if (x > static_cast<int64_t>(sw) - w ||
          y > static_cast<int64_t>(sh) - h ||
          bytes > (reference ? (256u << 20) : (40u << 20)))
        throw E_INVALIDARG;
      auto start = std::chrono::steady_clock::now();
      std::vector<uint8_t> storage(static_cast<size_t>(bytes) + 128, 0xa7);
      auto *pixels = storage.data() + 64;
      ComPtr<IWICBitmapScaler> scaler;
      ComPtr<IWICFormatConverter> converter;
      ComPtr<IWICColorTransform> transform;
      ComPtr<IWICBitmap> webpBitmap;
      IWICBitmapSource *output = nullptr;
      std::vector<uint8_t> coarse;
      bool globalWebp = false;
      if (webp) {
        WebPDecoderConfig config{};
        if (!WebPInitDecoderConfig(&config))
          throw E_FAIL;
        if (level) {
          // 同一全局层缩放一次，避免各区域独立缩放的相位差；粗层临时像素有单独上限。
          if (uint64_t(sw) * sh * 4 > (40u << 20))
            throw E_NOTIMPL;
          coarse.resize(static_cast<size_t>(sw) * sh * 4);
          globalWebp = true;
          config.options.use_scaling = 1;
          config.options.scaled_width = sw;
          config.options.scaled_height = sh;
        } else {
          config.options.use_cropping = 1;
          config.options.crop_left = x;
          config.options.crop_top = y;
          config.options.crop_width = w;
          config.options.crop_height = h;
        }
        config.output.colorspace = MODE_rgbA;
        config.output.is_external_memory = 1;
        config.output.u.RGBA.rgba = globalWebp ? coarse.data() : pixels;
        config.output.u.RGBA.stride = globalWebp ? sw * 4 : w * 4;
        config.output.u.RGBA.size =
            globalWebp ? coarse.size() : static_cast<size_t>(bytes);
        const auto status =
            WebPDecode(encoded, static_cast<size_t>(length.QuadPart), &config);
        WebPFreeDecBuffer(&config.output);
        if (status != VP8_STATUS_OK)
          throw E_FAIL;
        if (hasICC || globalWebp) {
          Check(factory->CreateBitmapFromMemory(
              globalWebp ? sw : w, globalWebp ? sh : h,
              GUID_WICPixelFormat32bppPRGBA, globalWebp ? sw * 4 : w * 4,
              static_cast<UINT>(globalWebp ? coarse.size() : bytes),
              globalWebp ? coarse.data() : pixels, &webpBitmap));
          output = webpBitmap.Get();
        }
      } else {
        output = source.Get();
        if (level) {
          Check(factory->CreateBitmapScaler(&scaler));
          Check(scaler->Initialize(source.Get(), sw, sh,
                                   WICBitmapInterpolationModeFant));
          output = scaler.Get();
        }
        Check(factory->CreateFormatConverter(&converter));
        Check(converter->Initialize(output, GUID_WICPixelFormat32bppPRGBA,
                                    WICBitmapDitherTypeNone, nullptr, 0,
                                    WICBitmapPaletteTypeCustom));
        output = converter.Get();
      }
      if (hasICC) {
        Check(factory->CreateColorTransformer(&transform));
        Check(transform->Initialize(output, inputColor.Get(), outputColor.Get(),
                                    GUID_WICPixelFormat32bppPRGBA));
        output = transform.Get();
      }
      if (output) {
        const WICRect rect{webp && !globalWebp ? 0 : x,
                           webp && !globalWebp ? 0 : y, w, h};
        Check(
            output->CopyPixels(&rect, w * 4, static_cast<UINT>(bytes), pixels));
      }
      for (int i = 0; i < 64; i++)
        if (storage[i] != 0xa7 || storage[bytes + 64 + i] != 0xa7)
          throw E_FAIL;
      if (!pipe) {
        const auto dest =
            std::filesystem::path(argv[2]) / (std::to_wstring(index) + L".raw");
        std::ofstream out(dest, std::ios::binary);
        out.write(reinterpret_cast<const char *>(pixels),
                  static_cast<std::streamsize>(bytes));
        if (!out)
          throw E_FAIL;
      }
      const auto memory = Memory();
      const double ms = std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - start)
                            .count();
      std::cout << "{\"index\":" << index << ",\"width\":" << w
                << ",\"height\":" << h << ",\"bytes\":" << bytes
                << ",\"ms\":" << ms << ",\"private\":" << memory.PrivateUsage
                << ",\"peakPrivate\":" << memory.PeakPagefileUsage
                << ",\"guards\":true}\n";
      if (pipe)
        std::cout.write(reinterpret_cast<const char *>(pixels),
                        static_cast<std::streamsize>(bytes));
      std::cout.flush();
      if (!std::cout)
        throw E_FAIL;
    }
  } catch (HRESULT hr) {
    std::cout << "{\"error\":" << static_cast<int64_t>(hr) << "}" << std::endl;
    return 3;
  } catch (...) {
    std::cout << "{\"error\":-1}" << std::endl;
    return 4;
  }
  return 0;
}
