#include "go2_local_planner.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <csignal>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

#include <unitree/idl/go2/SportModeState_.hpp>
#include <unitree/idl/ros2/PointStamped_.hpp>
#include <unitree/robot/channel/channel_factory.hpp>
#include <unitree/robot/channel/channel_subscriber.hpp>
#include <unitree/robot/go2/obstacles_avoid/obstacles_avoid_client.hpp>

namespace {

constexpr const char* kRangeTopic = "rt/utlidar/range_info";
constexpr const char* kSportStateTopic = "rt/sportmodestate";
constexpr double kSensorMaxAgeS = 0.50;
constexpr auto kControlPeriod = std::chrono::milliseconds(50);

struct LatestSensors {
    go2::RangeSample range;
    go2::PoseSample pose;
    double range_received_s = 0.0;
    double pose_received_s = 0.0;
};

std::mutex g_sensor_mutex;
LatestSensors g_sensors;
std::atomic<bool> g_stop_requested{false};

double monotonic_seconds() {
    return std::chrono::duration<double>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void handle_signal(int) {
    g_stop_requested.store(true);
}

void handle_range(const void* message) {
    const auto* sample =
        static_cast<const geometry_msgs::msg::dds_::PointStamped_*>(message);
    std::lock_guard<std::mutex> lock(g_sensor_mutex);
    g_sensors.range.front_m = static_cast<float>(sample->point().x());
    g_sensors.range.left_m = static_cast<float>(sample->point().y());
    g_sensors.range.right_m = static_cast<float>(sample->point().z());
    g_sensors.range.valid = std::isfinite(g_sensors.range.front_m) &&
        std::isfinite(g_sensors.range.left_m) &&
        std::isfinite(g_sensors.range.right_m) &&
        g_sensors.range.front_m > 0.0f &&
        g_sensors.range.left_m > 0.0f &&
        g_sensors.range.right_m > 0.0f;
    g_sensors.range_received_s = monotonic_seconds();
}

void handle_sport_state(const void* message) {
    const auto* sample =
        static_cast<const unitree_go::msg::dds_::SportModeState_*>(message);
    std::lock_guard<std::mutex> lock(g_sensor_mutex);
    g_sensors.pose.x_m = sample->position()[0];
    g_sensors.pose.y_m = sample->position()[1];
    g_sensors.pose.yaw_rad = sample->imu_state().rpy()[2];
    g_sensors.pose.valid = std::isfinite(g_sensors.pose.x_m) &&
        std::isfinite(g_sensors.pose.y_m) &&
        std::isfinite(g_sensors.pose.yaw_rad);
    g_sensors.pose_received_s = monotonic_seconds();
}

LatestSensors sensor_snapshot() {
    std::lock_guard<std::mutex> lock(g_sensor_mutex);
    return g_sensors;
}

float parse_float(const char* value, float fallback) {
    try {
        return std::stof(value);
    } catch (...) {
        return fallback;
    }
}

int parse_int(const char* value, int fallback) {
    try {
        return std::stoi(value);
    } catch (...) {
        return fallback;
    }
}

template <typename Callable>
int retry_busy(const char* label, Callable call) {
    int code = 3104;
    for (int attempt = 1; attempt <= 6; ++attempt) {
        code = call();
        std::cout << label << " attempt=" << attempt << " code=" << code
                  << std::endl;
        if (code != 3104) return code;
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    return code;
}

void stop_and_release(unitree::robot::go2::ObstaclesAvoidClient& client) {
    for (int i = 0; i < 8; ++i) {
        client.Move(0.0f, 0.0f, 0.0f);
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
    }
    const int release_code = retry_busy("ReleaseRemoteCommand", [&client]() {
        return client.UseRemoteCommandFromApi(false);
    });
    std::cout << "SAFE_STOP release_code=" << release_code << std::endl;
}

}  // namespace

int main(int argc, char** argv) {
    std::cout << std::unitbuf;
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    const std::string interface = argc > 1 ? argv[1] : "eth0";
    const bool probe_only = argc > 2 && std::string(argv[2]) == "--probe";
    go2::PlannerConfig config;
    config.target_distance_m = std::clamp(
        argc > 2 && !probe_only ? parse_float(argv[2], 20.0f) : 20.0f,
        0.5f, 60.0f);
    config.forward_speed_mps = std::clamp(
        argc > 3 ? parse_float(argv[3], 0.22f) : 0.22f, 0.10f, 0.35f);
    config.stop_distance_m = std::clamp(
        argc > 4 ? parse_float(argv[4], 0.80f) : 0.80f, 0.40f, 1.50f);
    config.min_side_clearance_m = std::clamp(
        argc > 5 ? parse_float(argv[5], 1.20f) : 1.20f, 0.40f, 1.50f);
    config.lateral_shift_m = std::clamp(
        argc > 6 ? parse_float(argv[6], 0.80f) : 0.80f, 0.40f, 1.50f);
    config.max_bypass_attempts = std::clamp(
        argc > 7 ? parse_int(argv[7], 2) : 2, 0, 4);
    config.resume_distance_m = std::max(config.stop_distance_m + 0.25f, 1.10f);

    std::cout << (probe_only ? "LIDAR_PROBE_START" : "LIDAR_NAV_START")
              << " interface=" << interface
              << " target_m=" << config.target_distance_m
              << " forward_mps=" << config.forward_speed_mps
              << " stop_m=" << config.stop_distance_m
              << " side_clearance_m=" << config.min_side_clearance_m
              << " lateral_shift_m=" << config.lateral_shift_m
              << " max_attempts=" << config.max_bypass_attempts << std::endl;

    unitree::robot::ChannelFactory::Instance()->Init(0, interface);
    unitree::robot::ChannelSubscriber<geometry_msgs::msg::dds_::PointStamped_>
        range_subscriber(kRangeTopic);
    unitree::robot::ChannelSubscriber<unitree_go::msg::dds_::SportModeState_>
        state_subscriber(kSportStateTopic);
    range_subscriber.InitChannel(handle_range);
    state_subscriber.InitChannel(handle_sport_state);

    const double sensor_deadline_s = monotonic_seconds() + 8.0;
    while (!g_stop_requested.load() && monotonic_seconds() < sensor_deadline_s) {
        const LatestSensors sensors = sensor_snapshot();
        if (sensors.range.valid && sensors.pose.valid) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    const LatestSensors initial_sensors = sensor_snapshot();
    if (!initial_sensors.range.valid || !initial_sensors.pose.valid) {
        std::cerr << "SENSOR_FAULT LiDAR range or sport odometry did not start"
                  << std::endl;
        return 7;
    }
    if (probe_only) {
        std::cout << "LIDAR_PROBE_OK front_m=" << initial_sensors.range.front_m
                  << " left_m=" << initial_sensors.range.left_m
                  << " right_m=" << initial_sensors.range.right_m
                  << " pose_x_m=" << initial_sensors.pose.x_m
                  << " pose_y_m=" << initial_sensors.pose.y_m
                  << " yaw_rad=" << initial_sensors.pose.yaw_rad << std::endl;
        return 0;
    }

    unitree::robot::go2::ObstaclesAvoidClient client;
    client.SetTimeout(3.0f);
    client.Init();

    int result_code = 0;
    bool remote_command_claimed = false;
    try {
        int code = retry_busy("SwitchSet", [&client]() {
            return client.SwitchSet(true);
        });
        if (code != 0) throw std::runtime_error("failed to enable obstacle avoidance");
        code = retry_busy("UseRemoteCommandFromApi", [&client]() {
            return client.UseRemoteCommandFromApi(true);
        });
        if (code != 0) throw std::runtime_error("failed to claim movement command authority");
        remote_command_claimed = true;

        go2::LocalPlanner planner(config);
        go2::NavigationState last_state = go2::NavigationState::kWaitingForSensors;
        const double max_runtime_s = std::clamp(
            static_cast<double>(config.target_distance_m / config.forward_speed_mps) *
                4.0 + 120.0,
            180.0, 1200.0);
        const double runtime_deadline_s = monotonic_seconds() + max_runtime_s;
        int move_failures = 0;
        auto next_tick = std::chrono::steady_clock::now();

        while (!g_stop_requested.load()) {
            const double now_s = monotonic_seconds();
            if (now_s >= runtime_deadline_s) {
                planner.fail("Navigation exceeded its maximum runtime");
            }

            const LatestSensors sensors = sensor_snapshot();
            go2::PlannerInput input;
            input.range = sensors.range;
            input.pose = sensors.pose;
            input.now_s = now_s;
            input.range_fresh = sensors.range_received_s > 0.0 &&
                now_s - sensors.range_received_s <= kSensorMaxAgeS;
            input.pose_fresh = sensors.pose_received_s > 0.0 &&
                now_s - sensors.pose_received_s <= kSensorMaxAgeS;
            const go2::PlannerOutput command = planner.update(input);

            if (command.state != last_state) {
                std::cout << "STATE " << go2::navigation_state_name(command.state)
                          << " progress_m=" << command.forward_progress_m
                          << " lateral_m=" << command.lateral_offset_m
                          << " attempts=" << command.bypass_attempts
                          << " reason=" << command.reason << std::endl;
                last_state = command.state;
            }

            code = client.Move(command.vx, command.vy, command.yaw_rate);
            if (code == 0) {
                move_failures = 0;
            } else if (++move_failures >= 4) {
                planner.fail("Repeated obstacle-avoidance Move RPC failures");
            }

            if (command.terminal) {
                result_code = command.state == go2::NavigationState::kComplete
                    ? 0
                    : (command.state == go2::NavigationState::kSensorFault ? 7 : 6);
                break;
            }

            next_tick += kControlPeriod;
            std::this_thread::sleep_until(next_tick);
        }

        if (g_stop_requested.load()) {
            std::cout << "CANCELLED external stop requested" << std::endl;
            result_code = 130;
        }
    } catch (const std::exception& error) {
        std::cerr << "NAVIGATION_ERROR " << error.what() << std::endl;
        result_code = 9;
    }

    if (remote_command_claimed) {
        stop_and_release(client);
    } else {
        for (int i = 0; i < 5; ++i) {
            client.Move(0.0f, 0.0f, 0.0f);
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
        }
    }
    std::cout << "LIDAR_NAV_DONE code=" << result_code << std::endl;
    return result_code;
}
