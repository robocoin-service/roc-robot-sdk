#pragma once

#include <string>

namespace go2 {

enum class NavigationState {
    kWaitingForSensors,
    kForward,
    kEvaluate,
    kShiftOut,
    kPassObstacle,
    kShiftBack,
    kComplete,
    kBlocked,
    kSensorFault,
};

const char* navigation_state_name(NavigationState state);

struct RangeSample {
    float front_m = 0.0f;
    float left_m = 0.0f;
    float right_m = 0.0f;
    bool valid = false;
};

struct PoseSample {
    float x_m = 0.0f;
    float y_m = 0.0f;
    float yaw_rad = 0.0f;
    bool valid = false;
};

struct PlannerConfig {
    float target_distance_m = 20.0f;
    float forward_speed_mps = 0.22f;
    float lateral_speed_mps = 0.14f;
    float stop_distance_m = 0.80f;
    float resume_distance_m = 1.10f;
    float min_side_clearance_m = 1.20f;
    float side_stop_distance_m = 0.35f;
    float lateral_shift_m = 0.80f;
    float bypass_forward_distance_m = 1.20f;
    float rejoin_tolerance_m = 0.08f;
    float motion_progress_epsilon_m = 0.01f;
    float motion_stall_timeout_s = 3.0f;
    int blocked_frames = 3;
    int clear_frames = 3;
    int max_bypass_attempts = 2;
};

struct PlannerInput {
    RangeSample range;
    PoseSample pose;
    double now_s = 0.0;
    bool range_fresh = false;
    bool pose_fresh = false;
};

struct PlannerOutput {
    float vx = 0.0f;
    float vy = 0.0f;
    float yaw_rate = 0.0f;
    bool stop = true;
    bool terminal = false;
    NavigationState state = NavigationState::kWaitingForSensors;
    float forward_progress_m = 0.0f;
    float lateral_offset_m = 0.0f;
    int bypass_attempts = 0;
    std::string reason;
};

class LocalPlanner {
public:
    explicit LocalPlanner(PlannerConfig config = {});

    PlannerOutput update(const PlannerInput& input);
    void fail(const std::string& reason, bool sensor_fault = false);

    NavigationState state() const { return state_; }
    const std::string& reason() const { return reason_; }
    int bypass_attempts() const { return bypass_attempts_; }

private:
    PlannerOutput output(float vx, float vy, bool terminal = false);
    void update_route_coordinates(const PoseSample& pose);
    bool side_is_clear(const RangeSample& range, int side_sign) const;

    PlannerConfig config_;
    NavigationState state_ = NavigationState::kWaitingForSensors;
    std::string reason_ = "Waiting for LiDAR range and odometry";
    bool initialized_ = false;
    bool complete_after_rejoin_ = false;
    bool previous_output_moving_ = false;
    float origin_x_m_ = 0.0f;
    float origin_y_m_ = 0.0f;
    float origin_yaw_rad_ = 0.0f;
    float forward_progress_m_ = 0.0f;
    float lateral_offset_m_ = 0.0f;
    float shift_goal_offset_m_ = 0.0f;
    float bypass_start_progress_m_ = 0.0f;
    float motion_anchor_x_m_ = 0.0f;
    float motion_anchor_y_m_ = 0.0f;
    double last_motion_progress_s_ = 0.0;
    int selected_side_sign_ = 0;
    int blocked_count_ = 0;
    int clear_count_ = 0;
    int bypass_attempts_ = 0;
};

}  // namespace go2
