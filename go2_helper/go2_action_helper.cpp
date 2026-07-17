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

template <typename Callable>
int call_with_timeout_retry(const std::string &label, Callable callable) {
    int code = 0;
    for (int attempt = 1; attempt <= 3; ++attempt) {
        code = callable();
        std::cout << label << " attempt=" << attempt << " code=" << code << std::endl;
        if (code == 0 || code != 3104) return code;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    return code;
}

int hold_still(unitree::robot::go2::SportClient &client, int repeats = 10) {
    int code = 0;
    bool sent_successfully = false;
    for (int i = 0; i < repeats; ++i) {
        code = client.Move(0.0f, 0.0f, 0.0f);
        if (code != 0 && code != 3104) return code;
        if (code == 0) sent_successfully = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    return sent_successfully ? 0 : code;
}

int run_velocity_segment(unitree::robot::go2::SportClient &client,
                         const std::string &label,
                         float vx, float vy, float vyaw, int duration_ms) {
    std::cout << "SEGMENT " << label << " START duration_ms=" << duration_ms << std::endl;
    int code = 0;
    int timeout_retries = 0;
    int successful_motion_ms = 0;
    while (successful_motion_ms < duration_ms) {
        code = client.Move(vx, vy, vyaw);
        if (code == 3104 && timeout_retries < 3) {
            ++timeout_retries;
            std::this_thread::sleep_for(std::chrono::milliseconds(300));
            continue;
        }
        if (code != 0) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        successful_motion_ms += 20;
    }
    std::cout << "SEGMENT " << label << " code=" << code << std::endl;
    if (code != 0) return code;
    return hold_still(client);
}

int prepare_motion(unitree::robot::go2::SportClient &client) {
    const int stand_code = call_with_timeout_retry("BalanceStand", [&client]() {
        return client.BalanceStand();
    });
    if (stand_code != 0) return stand_code;
    std::this_thread::sleep_for(std::chrono::milliseconds(600));

    const int gait_code = call_with_timeout_retry("SwitchGait", [&client]() {
        return client.SwitchGait(1);
    });
    if (gait_code != 0) return gait_code;
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    return 0;
}

int run_patrol(unitree::robot::go2::SportClient &client, float distance, float turn_seconds) {
    const float forward_speed = 0.30f;
    const float yaw_rate = 0.80f;
    const int forward_ms = static_cast<int>(distance / forward_speed * 1000.0f);
    const int turn_ms = static_cast<int>(turn_seconds * 1000.0f);

    int code = prepare_motion(client);
    if (code != 0) return 4;
    code = run_velocity_segment(client, "FORWARD_1", forward_speed, 0.0f, 0.0f, forward_ms);
    if (code != 0) return 10;
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    code = run_velocity_segment(client, "TURN", 0.0f, 0.0f, yaw_rate, turn_ms);
    if (code != 0) return 11;
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    code = run_velocity_segment(client, "FORWARD_2", forward_speed, 0.0f, 0.0f, forward_ms);
    if (code != 0) return 12;

    const int stop_code = call_with_timeout_retry("StopMove", [&client]() {
        return client.StopMove();
    });
    const int zero_code = hold_still(client);
    std::cout << "PATROL_DONE stop_code=" << stop_code << " zero_code=" << zero_code << std::endl;
    return zero_code == 0 ? 0 : 13;
}

}  // namespace

int main(int argc, char **argv) {
    const std::string iface = argc > 1 ? argv[1] : "eth0";
    const std::string action = argc > 2 ? argv[2] : "stop";
    const bool named_action = action == "stand_up" || action == "heart" ||
                              action == "dance1" || action == "dance2";
    const bool patrol_action = action == "patrol";

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

    if (patrol_action) {
        float distance = argc > 3 ? parse_float(argv[3], 10.0f) : 10.0f;
        float turn_seconds = argc > 4 ? parse_float(argv[4], 9.0f) : 9.0f;
        distance = std::max(0.5f, std::min(distance, 20.0f));
        turn_seconds = std::max(1.0f, std::min(turn_seconds, 12.0f));
        std::cout << "PATROL distance=" << distance << " turn_seconds=" << turn_seconds << std::endl;
        return run_patrol(client, distance, turn_seconds);
    }

    float vx = argc > 2 ? parse_float(argv[2], 0.0f) : 0.0f;
    float vy = argc > 3 ? parse_float(argv[3], 0.0f) : 0.0f;
    float vyaw = argc > 4 ? parse_float(argv[4], 0.0f) : 0.0f;
    int duration_ms = argc > 5 ? parse_int(argv[5], 0) : 0;

    duration_ms = std::max(0, std::min(duration_ms, 240000));
    vx = std::max(-0.80f, std::min(vx, 0.80f));
    vy = std::max(-0.30f, std::min(vy, 0.30f));
    vyaw = std::max(-0.90f, std::min(vyaw, 0.90f));

    const bool wants_motion = duration_ms > 0 || vx != 0.0f || vy != 0.0f || vyaw != 0.0f;
    int move_code = 0;
    if (wants_motion) {
        const int stand_code = prepare_motion(client);
        if (stand_code != 0) return 4;

        const auto start = std::chrono::steady_clock::now();
        const auto deadline = start + std::chrono::milliseconds(duration_ms);
        const bool ramp_linear = vyaw == 0.0f && (vx != 0.0f || vy != 0.0f);
        constexpr float ramp_ms = 800.0f;
        do {
            const auto now = std::chrono::steady_clock::now();
            float scale = 1.0f;
            if (ramp_linear) {
                const float elapsed_ms = static_cast<float>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(now - start).count());
                const float remaining_ms = static_cast<float>(
                    std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
                scale = std::max(0.0f, std::min(1.0f, std::min(elapsed_ms / ramp_ms, remaining_ms / ramp_ms)));
            }
            move_code = client.Move(vx * scale, vy * scale, vyaw);
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
