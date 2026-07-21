#include "go2_local_planner.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace go2 {

namespace {

bool finite_positive(float value) {
    return std::isfinite(value) && value > 0.0f;
}

}  // namespace

const char* navigation_state_name(NavigationState state) {
    switch (state) {
        case NavigationState::kWaitingForSensors: return "WAITING_FOR_SENSORS";
        case NavigationState::kForward: return "FORWARD";
        case NavigationState::kEvaluate: return "EVALUATE";
        case NavigationState::kShiftOut: return "SHIFT_OUT";
        case NavigationState::kPassObstacle: return "PASS_OBSTACLE";
        case NavigationState::kShiftBack: return "SHIFT_BACK";
        case NavigationState::kComplete: return "COMPLETE";
        case NavigationState::kBlocked: return "BLOCKED";
        case NavigationState::kSensorFault: return "SENSOR_FAULT";
    }
    return "UNKNOWN";
}

LocalPlanner::LocalPlanner(PlannerConfig config) : config_(std::move(config)) {
    config_.target_distance_m = std::max(0.1f, config_.target_distance_m);
    config_.forward_speed_mps = std::max(0.05f, config_.forward_speed_mps);
    config_.lateral_speed_mps = std::max(0.05f, config_.lateral_speed_mps);
    config_.stop_distance_m = std::max(0.20f, config_.stop_distance_m);
    config_.resume_distance_m = std::max(config_.stop_distance_m + 0.10f,
                                         config_.resume_distance_m);
    config_.min_side_clearance_m = std::max(0.20f, config_.min_side_clearance_m);
    config_.side_stop_distance_m = std::max(0.10f, config_.side_stop_distance_m);
    config_.lateral_shift_m = std::max(0.20f, config_.lateral_shift_m);
    config_.min_side_clearance_m = std::max(
        config_.min_side_clearance_m,
        config_.lateral_shift_m + config_.side_stop_distance_m);
    config_.bypass_forward_distance_m = std::max(0.30f,
                                                  config_.bypass_forward_distance_m);
    config_.rejoin_tolerance_m = std::max(0.02f, config_.rejoin_tolerance_m);
    config_.motion_stall_timeout_s = std::max(0.5f, config_.motion_stall_timeout_s);
    config_.blocked_frames = std::max(1, config_.blocked_frames);
    config_.clear_frames = std::max(1, config_.clear_frames);
    config_.max_bypass_attempts = std::max(0, config_.max_bypass_attempts);
}

void LocalPlanner::fail(const std::string& reason, bool sensor_fault) {
    state_ = sensor_fault ? NavigationState::kSensorFault : NavigationState::kBlocked;
    reason_ = reason;
    previous_output_moving_ = false;
}

void LocalPlanner::update_route_coordinates(const PoseSample& pose) {
    const float dx = pose.x_m - origin_x_m_;
    const float dy = pose.y_m - origin_y_m_;
    const float cos_yaw = std::cos(origin_yaw_rad_);
    const float sin_yaw = std::sin(origin_yaw_rad_);
    forward_progress_m_ = dx * cos_yaw + dy * sin_yaw;
    lateral_offset_m_ = -dx * sin_yaw + dy * cos_yaw;
}

bool LocalPlanner::side_is_clear(const RangeSample& range, int side_sign) const {
    const float distance = side_sign > 0 ? range.left_m : range.right_m;
    return finite_positive(distance) && distance >= config_.side_stop_distance_m;
}

PlannerOutput LocalPlanner::output(float vx, float vy, bool terminal) {
    PlannerOutput result;
    result.vx = vx;
    result.vy = vy;
    result.stop = vx == 0.0f && vy == 0.0f;
    result.terminal = terminal;
    result.state = state_;
    result.forward_progress_m = forward_progress_m_;
    result.lateral_offset_m = lateral_offset_m_;
    result.bypass_attempts = bypass_attempts_;
    result.reason = reason_;
    previous_output_moving_ = !result.stop;
    return result;
}

PlannerOutput LocalPlanner::update(const PlannerInput& input) {
    const bool values_valid = input.range.valid && input.pose.valid &&
        finite_positive(input.range.front_m) &&
        finite_positive(input.range.left_m) &&
        finite_positive(input.range.right_m) &&
        std::isfinite(input.pose.x_m) && std::isfinite(input.pose.y_m) &&
        std::isfinite(input.pose.yaw_rad);

    if (!initialized_) {
        if (!input.range_fresh || !input.pose_fresh || !values_valid) {
            return output(0.0f, 0.0f);
        }
        initialized_ = true;
        origin_x_m_ = input.pose.x_m;
        origin_y_m_ = input.pose.y_m;
        origin_yaw_rad_ = input.pose.yaw_rad;
        motion_anchor_x_m_ = input.pose.x_m;
        motion_anchor_y_m_ = input.pose.y_m;
        last_motion_progress_s_ = input.now_s;
        state_ = NavigationState::kForward;
        reason_ = "LiDAR and odometry ready";
    } else if (!input.range_fresh || !input.pose_fresh || !values_valid) {
        fail("LiDAR range or odometry became stale", true);
        return output(0.0f, 0.0f, true);
    }

    update_route_coordinates(input.pose);

    if (previous_output_moving_) {
        const float moved = std::hypot(input.pose.x_m - motion_anchor_x_m_,
                                       input.pose.y_m - motion_anchor_y_m_);
        if (moved >= config_.motion_progress_epsilon_m) {
            motion_anchor_x_m_ = input.pose.x_m;
            motion_anchor_y_m_ = input.pose.y_m;
            last_motion_progress_s_ = input.now_s;
        } else if (input.now_s - last_motion_progress_s_ >=
                   config_.motion_stall_timeout_s) {
            fail("Motion command made no odometry progress");
            return output(0.0f, 0.0f, true);
        }
    } else {
        motion_anchor_x_m_ = input.pose.x_m;
        motion_anchor_y_m_ = input.pose.y_m;
        last_motion_progress_s_ = input.now_s;
    }

    if (state_ == NavigationState::kBlocked ||
        state_ == NavigationState::kSensorFault ||
        state_ == NavigationState::kComplete) {
        return output(0.0f, 0.0f, true);
    }

    if (state_ == NavigationState::kForward) {
        if (forward_progress_m_ >= config_.target_distance_m) {
            state_ = NavigationState::kComplete;
            reason_ = "Target distance reached";
            return output(0.0f, 0.0f, true);
        }
        if (input.range.front_m <= config_.stop_distance_m) {
            ++blocked_count_;
        } else {
            blocked_count_ = 0;
        }
        if (blocked_count_ >= config_.blocked_frames) {
            state_ = NavigationState::kEvaluate;
            reason_ = "Obstacle confirmed ahead; evaluating side clearance";
            blocked_count_ = 0;
            return output(0.0f, 0.0f);
        }
        reason_ = "Following original route";
        return output(config_.forward_speed_mps, 0.0f);
    }

    if (state_ == NavigationState::kEvaluate) {
        if (bypass_attempts_ >= config_.max_bypass_attempts) {
            fail("Maximum bypass attempts reached");
            return output(0.0f, 0.0f, true);
        }
        const float best_clearance = std::max(input.range.left_m,
                                              input.range.right_m);
        if (best_clearance < config_.min_side_clearance_m) {
            fail("Neither side has the required clearance");
            return output(0.0f, 0.0f, true);
        }
        selected_side_sign_ = input.range.left_m >= input.range.right_m ? 1 : -1;
        shift_goal_offset_m_ = selected_side_sign_ * config_.lateral_shift_m;
        ++bypass_attempts_;
        state_ = NavigationState::kShiftOut;
        reason_ = selected_side_sign_ > 0 ? "Bypassing on the left" :
                                            "Bypassing on the right";
    }

    if (state_ == NavigationState::kShiftOut) {
        if (!side_is_clear(input.range, selected_side_sign_)) {
            fail("Selected side became unsafe during lateral shift");
            return output(0.0f, 0.0f, true);
        }
        const bool reached = selected_side_sign_ > 0
            ? lateral_offset_m_ >= shift_goal_offset_m_ - config_.rejoin_tolerance_m
            : lateral_offset_m_ <= shift_goal_offset_m_ + config_.rejoin_tolerance_m;
        if (reached) {
            bypass_start_progress_m_ = forward_progress_m_;
            clear_count_ = 0;
            state_ = NavigationState::kPassObstacle;
            reason_ = "Lateral clearance reached; passing obstacle";
        } else {
            return output(0.0f, selected_side_sign_ * config_.lateral_speed_mps);
        }
    }

    if (state_ == NavigationState::kPassObstacle) {
        if (input.range.front_m <= config_.stop_distance_m) {
            fail("Bypass corridor is blocked ahead");
            return output(0.0f, 0.0f, true);
        }
        if (input.range.front_m >= config_.resume_distance_m) {
            ++clear_count_;
        } else {
            clear_count_ = 0;
        }
        const bool passed_distance = forward_progress_m_ - bypass_start_progress_m_ >=
            config_.bypass_forward_distance_m;
        if (forward_progress_m_ >= config_.target_distance_m) {
            complete_after_rejoin_ = true;
            state_ = NavigationState::kShiftBack;
            reason_ = "Target reached off route; returning to route center";
        } else if (passed_distance && clear_count_ >= config_.clear_frames) {
            state_ = NavigationState::kShiftBack;
            reason_ = "Obstacle passed; returning to original route";
        } else {
            return output(config_.forward_speed_mps, 0.0f);
        }
    }

    if (state_ == NavigationState::kShiftBack) {
        const int return_side_sign = -selected_side_sign_;
        if (!side_is_clear(input.range, return_side_sign)) {
            fail("Return path to the original route became unsafe");
            return output(0.0f, 0.0f, true);
        }
        if (input.range.front_m <= config_.stop_distance_m) {
            fail("Obstacle appeared ahead while returning to route");
            return output(0.0f, 0.0f, true);
        }
        const bool rejoined = std::abs(lateral_offset_m_) <=
            config_.rejoin_tolerance_m;
        if (!rejoined) {
            return output(0.0f, return_side_sign * config_.lateral_speed_mps);
        }
        selected_side_sign_ = 0;
        if (complete_after_rejoin_ ||
            forward_progress_m_ >= config_.target_distance_m) {
            state_ = NavigationState::kComplete;
            reason_ = "Target distance reached and route center restored";
            return output(0.0f, 0.0f, true);
        }
        state_ = NavigationState::kForward;
        reason_ = "Original route restored";
        blocked_count_ = 0;
        clear_count_ = 0;
        return output(config_.forward_speed_mps, 0.0f);
    }

    fail("Planner entered an invalid state");
    return output(0.0f, 0.0f, true);
}

}  // namespace go2
