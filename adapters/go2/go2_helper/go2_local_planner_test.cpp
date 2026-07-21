#include "go2_local_planner.hpp"

#include <cassert>
#include <cmath>
#include <iostream>

namespace {

go2::PlannerInput input(float front, float left, float right,
                        float x, float y, double now_s,
                        bool fresh = true) {
    go2::PlannerInput value;
    value.range = {front, left, right, true};
    value.pose = {x, y, 0.0f, true};
    value.now_s = now_s;
    value.range_fresh = fresh;
    value.pose_fresh = fresh;
    return value;
}

void clear_route_reaches_target() {
    go2::PlannerConfig config;
    config.target_distance_m = 1.0f;
    config.forward_speed_mps = 0.20f;
    go2::LocalPlanner planner(config);
    float x = 0.0f;
    double now = 0.0;
    for (int i = 0; i < 200 && planner.state() != go2::NavigationState::kComplete;
         ++i) {
        const auto command = planner.update(input(5.0f, 5.0f, 5.0f, x, 0.0f, now));
        x += command.vx * 0.05f;
        now += 0.05;
    }
    assert(planner.state() == go2::NavigationState::kComplete);
}

void obstacle_uses_clearer_left_side_and_rejoins() {
    go2::PlannerConfig config;
    config.target_distance_m = 2.0f;
    config.forward_speed_mps = 0.20f;
    config.lateral_speed_mps = 0.20f;
    config.stop_distance_m = 0.80f;
    config.resume_distance_m = 1.10f;
    config.min_side_clearance_m = 0.70f;
    config.side_stop_distance_m = 0.20f;
    config.lateral_shift_m = 0.40f;
    config.bypass_forward_distance_m = 0.50f;
    config.rejoin_tolerance_m = 0.03f;
    config.blocked_frames = 2;
    go2::LocalPlanner planner(config);

    float x = 0.0f;
    float y = 0.0f;
    double now = 0.0;
    bool shifted_left = false;
    bool shifted_right = false;
    for (int i = 0; i < 500 && planner.state() != go2::NavigationState::kComplete;
         ++i) {
        const bool obstacle_ahead = x < 0.15f && y < 0.25f;
        const auto command = planner.update(input(
            obstacle_ahead ? 0.50f : 5.0f, 2.0f, 0.30f, x, y, now));
        shifted_left = shifted_left || command.vy > 0.0f;
        shifted_right = shifted_right || command.vy < 0.0f;
        x += command.vx * 0.05f;
        y += command.vy * 0.05f;
        now += 0.05;
        assert(planner.state() != go2::NavigationState::kBlocked);
        assert(planner.state() != go2::NavigationState::kSensorFault);
    }
    assert(shifted_left);
    assert(shifted_right);
    assert(planner.bypass_attempts() == 1);
    assert(planner.state() == go2::NavigationState::kComplete);
    assert(std::abs(y) <= config.rejoin_tolerance_m + 0.02f);
}

void unsafe_sides_stop_without_blind_motion() {
    go2::PlannerConfig config;
    config.blocked_frames = 1;
    config.min_side_clearance_m = 0.70f;
    go2::LocalPlanner planner(config);
    planner.update(input(0.50f, 0.30f, 0.25f, 0.0f, 0.0f, 0.0));
    const auto result = planner.update(input(0.50f, 0.30f, 0.25f,
                                             0.0f, 0.0f, 0.1));
    assert(result.stop);
    assert(result.terminal);
    assert(result.state == go2::NavigationState::kBlocked);
}

void stale_sensor_stops_navigation() {
    go2::LocalPlanner planner;
    planner.update(input(5.0f, 5.0f, 5.0f, 0.0f, 0.0f, 0.0));
    const auto result = planner.update(input(5.0f, 5.0f, 5.0f,
                                             0.01f, 0.0f, 0.1, false));
    assert(result.stop);
    assert(result.terminal);
    assert(result.state == go2::NavigationState::kSensorFault);
}

void stalled_motion_stops_navigation() {
    go2::PlannerConfig config;
    config.motion_stall_timeout_s = 0.50f;
    config.motion_progress_epsilon_m = 0.01f;
    go2::LocalPlanner planner(config);
    planner.update(input(5.0f, 5.0f, 5.0f, 0.0f, 0.0f, 0.0));
    planner.update(input(5.0f, 5.0f, 5.0f, 0.0f, 0.0f, 0.3));
    const auto result = planner.update(input(5.0f, 5.0f, 5.0f,
                                             0.0f, 0.0f, 0.6));
    assert(result.stop);
    assert(result.terminal);
    assert(result.state == go2::NavigationState::kBlocked);
}

}  // namespace

int main() {
    clear_route_reaches_target();
    obstacle_uses_clearer_left_side_and_rejoins();
    unsafe_sides_stop_without_blind_motion();
    stale_sensor_stops_navigation();
    stalled_motion_stops_navigation();
    std::cout << "go2_local_planner tests passed" << std::endl;
    return 0;
}
