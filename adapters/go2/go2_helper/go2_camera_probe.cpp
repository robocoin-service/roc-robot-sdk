#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/go2/video/video_client.hpp>

namespace {

bool is_start_of_frame(uint8_t marker) {
    switch (marker) {
        case 0xC0:
        case 0xC1:
        case 0xC2:
        case 0xC3:
        case 0xC5:
        case 0xC6:
        case 0xC7:
        case 0xC9:
        case 0xCA:
        case 0xCB:
        case 0xCD:
        case 0xCE:
        case 0xCF:
            return true;
        default:
            return false;
    }
}

bool jpeg_dimensions(const std::vector<uint8_t>& data, int& width, int& height) {
    if (data.size() < 10 || data[0] != 0xFF || data[1] != 0xD8) return false;
    std::size_t offset = 2;
    while (offset + 8 < data.size()) {
        if (data[offset] != 0xFF) {
            ++offset;
            continue;
        }
        const uint8_t marker = data[offset + 1];
        if (marker == 0xD8 || marker == 0xD9) {
            offset += 2;
            continue;
        }
        if (offset + 3 >= data.size()) return false;
        const std::size_t segment_length =
            (static_cast<std::size_t>(data[offset + 2]) << 8) |
            static_cast<std::size_t>(data[offset + 3]);
        if (segment_length < 2 || offset + 2 + segment_length > data.size()) {
            return false;
        }
        if (is_start_of_frame(marker) && segment_length >= 7) {
            height = (static_cast<int>(data[offset + 5]) << 8) |
                static_cast<int>(data[offset + 6]);
            width = (static_cast<int>(data[offset + 7]) << 8) |
                static_cast<int>(data[offset + 8]);
            return width > 0 && height > 0;
        }
        offset += 2 + segment_length;
    }
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    const std::string interface = argc > 1 ? argv[1] : "eth0";
    unitree::robot::ChannelFactory::Instance()->Init(0, interface);
    unitree::robot::go2::VideoClient client;
    client.SetTimeout(3.0f);
    client.Init();

    std::vector<uint8_t> image;
    const int code = client.GetImageSample(image);
    if (code != 0 || image.empty()) {
        std::cerr << "CAMERA_PROBE_FAILED code=" << code
                  << " bytes=" << image.size() << std::endl;
        return 2;
    }

    int width = 0;
    int height = 0;
    const bool jpeg = jpeg_dimensions(image, width, height);
    std::cout << "CAMERA_PROBE_OK code=" << code
              << " bytes=" << image.size()
              << " jpeg=" << (jpeg ? "true" : "false")
              << " width=" << width
              << " height=" << height << std::endl;
    return jpeg ? 0 : 3;
}
