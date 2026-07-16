#include <algorithm>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>

#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/go2/sport/sport_client.hpp>

namespace {

float parse_float(const char *value, float fallback) {
    try {
        return std::stof(value);
    } catch (...) {
        return fallback;
    }
}

int parse_int(const char *value, int fallback) {
    try {
        return std::stoi(value);
    } catch (...) {
        return fallback;
    }
}

int run_named_action(unitree::robot::go2::SportClient &client, const std::string &action) {
    if (action == "stand_up") return client.StandUp();
    if (action == "heart") return client.Heart();
    if (action == "dance1") return client.Dance1();
    if (action == "dance2") return client.Dance2();
    throw std::invalid_argument("unsupported named action: " + action);
}

}  // namespace

int main(int argc, char **argv) {
    const std::string iface = argc > 1 ? argv[1] : "eth0";
    const std::string action = argc > 2 ? argv[2] : "stop";
    const bool named_action = action == "stand_up" || action == "heart" ||
                              action == "dance1" || action == "dance2";

    unitree::robot::ChannelFactory::Instance()->Init(0, iface);
    unitree::robot::go2::SportClient client;
    client.SetTimeout(named_action ? 20.0f : 3.0f);
    client.Init();

    if (named_action) {
        const int code = run_named_action(client, action);
        std::cout << action << " code=" << code << std::endl;
        std::this_thread::sleep_for(std::chrono::milliseconds(800));
        return code == 0 ? 0 : 3;
    }

    float vx = argc > 2 ? parse_float(argv[2], 0.0f) : 0.0f;
    float vy = argc > 3 ? parse_float(argv[3], 0.0f) : 0.0f;
    float vyaw = argc > 4 ? parse_float(argv[4], 0.0f) : 0.0f;
    int duration_ms = argc > 5 ? parse_int(argv[5], 0) : 0;

    duration_ms = std::max(0, std::min(duration_ms, 45000));
    vx = std::max(-0.40f, std::min(vx, 0.40f));
    vy = std::max(-0.30f, std::min(vy, 0.30f));
    vyaw = std::max(-0.90f, std::min(vyaw, 0.90f));

    const bool wants_motion = duration_ms > 0 || vx != 0.0f || vy != 0.0f || vyaw != 0.0f;
    int move_code = 0;
    if (wants_motion) {
        const int stand_code = client.BalanceStand();
        std::cout << "BalanceStand code=" << stand_code << std::endl;
        if (stand_code != 0) return 4;
        std::this_thread::sleep_for(std::chrono::milliseconds(600));

        const int gait_code = client.SwitchGait(1);
        std::cout << "SwitchGait code=" << gait_code << std::endl;
        if (gait_code != 0) return 5;
        std::this_thread::sleep_for(std::chrono::milliseconds(200));

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(duration_ms);
        do {
            move_code = client.Move(vx, vy, vyaw);
            if (move_code != 0) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
        } while (std::chrono::steady_clock::now() < deadline);
        std::cout << "Move code=" << move_code << std::endl;
    }

    const int stop_code = client.StopMove();
    std::cout << "StopMove code=" << stop_code << std::endl;
    int zero_code = 0;
    for (int i = 0; i < 5; ++i) {
        zero_code = client.Move(0.0f, 0.0f, 0.0f);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    std::cout << "ZeroMove code=" << zero_code << std::endl;
    return move_code == 0 && zero_code == 0 ? 0 : 2;
}
