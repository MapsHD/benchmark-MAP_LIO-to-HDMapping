#!/bin/bash
# Run MAP_LIO on a rosbag (ROS 1 .bag or ROS 2 bag directory), record output
# topics, then convert the recorded bag to an HDMapping session.
#
# MAP_LIO does not subscribe to a played bag: it opens the bag itself (rosbag
# API) and processes it as fast as it can. Its odometry (/Odometry) and the
# registered scan in the world frame (/cloud_registered) are stamped with times
# taken from the input messages, i.e. bag time, so no /clock is involved. The
# recorder starts before MAP_LIO, because MAP_LIO publishes the registered scan
# only while someone subscribes to it. After the last message MAP_LIO prints
# "End of the bag file" and keeps spinning; the control window waits for that
# line and then shuts the session down.
#
# MAP_LIO reads the Hesai point format (float64 per-point timestamp). LiDAR
# clouds with a relative float32 per-point time instead (e.g. Livox clouds
# aggregated by livox_bag_aggregate) are converted to that format first, see
# overlay/scripts/map_lio_input.py.

IMAGE_NAME='map-lio_noetic'
TMUX_SESSION='ros1_map_lio'

DATASET_CONTAINER_PATH='/ros_ws/dataset/input.bag'
CONVERTED_BAG_CONTAINER='/tmp/dataset_ros1.bag'
HESAI_BAG_CONTAINER='/tmp/map_lio_input.bag'
BAG_OUTPUT_CONTAINER='/ros_ws/recordings'
CONFIG_MOUNT_CONTAINER='/ros_ws/config/map_lio.yaml'
CONFIG_DIR_CONTAINER='/ros_ws/src/MAP_LIO/config'

RECORDED_BAG_NAME="recorded-MAP_LIO.bag"
HDMAPPING_OUT_NAME="output_hdmapping"

# Recorded topics (used by the converter).
ODOM_TOPIC="${ODOM_TOPIC:-/Odometry}"
CLOUD_TOPIC="${CLOUD_TOPIC:-/cloud_registered}"

# MAP_LIO parameter file (LiDAR/IMU topics, extrinsics, noise, ranges): a file
# on the host, or the name of one shipped in the image (MAP_LIO's hesai.yaml,
# the benchmark's bunker.yaml). Default: the Bunker DVI dataset (Livox Mid-360).
CONFIG_FILE="${CONFIG_FILE:-bunker.yaml}"

# RViz on by default — the live view of how MAP_LIO tracks the dataset.
USE_RVIZ="${USE_RVIZ:-1}"

# Force Mesa software rendering by default so RViz renders even when the host
# GPU driver is not exposed to the container (the libGL "nvidia-drm" / amdgpu case).
LIBGL_SW="${LIBGL_SW:-1}"
if [[ "$LIBGL_SW" == "1" ]]; then LIBGL_ENV="1"; else LIBGL_ENV=""; fi

usage() {
  echo "Usage:"
  echo "  $0 <input.bag-or-ros2bag-dir> <output_dir>"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  CONFIG_FILE  - MAP_LIO parameter file: a host *.yaml, or hesai.yaml / bunker.yaml"
  echo "                 shipped in the image                (default: bunker.yaml)"
  echo "  ODOM_TOPIC   - MAP_LIO odometry output topic    (default: /Odometry)"
  echo "  CLOUD_TOPIC  - MAP_LIO registered cloud topic   (default: /cloud_registered)"
  echo "  USE_RVIZ     - 1/0, launch RViz live view       (default: 1)"
  exit 1
}

echo "=== MAP_LIO rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -e "$DATASET_HOST_PATH" ]]; then
  echo "Error: input does not exist: $DATASET_HOST_PATH"
  exit 1
fi

# Parameter file: a host file is mounted into the container; a plain name is
# a file shipped in the image (checked inside the container).
CONFIG_MOUNT=()
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE=$(realpath "$CONFIG_FILE")
  CONFIG_MOUNT=(-v "$CONFIG_FILE":"$CONFIG_MOUNT_CONTAINER":ro)
  CONFIG_CONTAINER="$CONFIG_MOUNT_CONTAINER"
  CONFIG_DESC="$CONFIG_FILE (host)"
elif [[ "$CONFIG_FILE" != */* ]]; then
  CONFIG_CONTAINER="$CONFIG_DIR_CONTAINER/$CONFIG_FILE"
  CONFIG_DESC="$CONFIG_FILE (shipped in the image)"
else
  echo "Error: CONFIG_FILE does not exist: $CONFIG_FILE"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# RViz on/off resolved to a roslaunch boolean
RVIZ_ARG=false; [[ "$USE_RVIZ" == "1" ]] && RVIZ_ARG=true

echo "Input           : $DATASET_HOST_PATH"
echo "Output dir      : $BAG_OUTPUT_HOST"
echo "Parameter file  : $CONFIG_DESC"
echo "Odom topic      : $ODOM_TOPIC"
echo "Cloud topic     : $CLOUD_TOPIC"

if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

xhost +local:docker >/dev/null

# ── Phase 1: run MAP_LIO + record output topics ──────────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ENV" \
  -e RVIZ_ARG="$RVIZ_ARG" \
  -e CONFIG_CONTAINER="$CONFIG_CONTAINER" \
  -e ODOM_TOPIC="$ODOM_TOPIC" \
  -e CLOUD_TOPIC="$CLOUD_TOPIC" \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "${CONFIG_MOUNT[@]}" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash

    # ── If input is a ROS 2 bag directory, convert to a ROS 1 bag ──────────
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Converting ROS 2 bag to ROS 1 bag format..."
      rm -f '"$CONVERTED_BAG_CONTAINER"'
      rosbags-convert '"$DATASET_CONTAINER_PATH"' --dst '"$CONVERTED_BAG_CONTAINER"' || {
        echo "[convert] ERROR: rosbags-convert failed"; exit 1; }
      ROS1_BAG="'"$CONVERTED_BAG_CONTAINER"'"
    else
      ROS1_BAG="'"$DATASET_CONTAINER_PATH"'"
    fi

    export ROS1_BAG
    echo "[convert] ROS 1 bag ready at: $ROS1_BAG"
    ls -la $ROS1_BAG

    # ── Input check + point format ──────────────────────────────────────────
    # The LiDAR and IMU topics of the parameter file must be in the bag,
    # otherwise MAP_LIO processes nothing and the run records no output.
    # Clouds with a relative per-point time are converted to the Hesai point
    # format into '"$HESAI_BAG_CONTAINER"' (written only then).
    rm -f '"$HESAI_BAG_CONTAINER"'
    if ! python3 /ros_ws/scripts/map_lio_input.py "$CONFIG_CONTAINER" "$ROS1_BAG" '"$HESAI_BAG_CONTAINER"'; then
      echo "[input] input check failed, nothing is run"
      exit 42
    fi
    if [[ -f '"$HESAI_BAG_CONTAINER"' ]]; then
      MAP_LIO_BAG='"$HESAI_BAG_CONTAINER"'
    else
      MAP_LIO_BAG="$ROS1_BAG"
    fi
    export MAP_LIO_BAG
    echo "[input] MAP_LIO reads: $MAP_LIO_BAG"

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: roscore ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[roscore] starting..."
roscore
'\'' C-m

    # ---------- PANE 1: rosbag record (before MAP_LIO starts) ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 4
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
rm -f '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
rosbag record $ODOM_TOPIC $CLOUD_TOPIC -O '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 2: MAP_LIO (+ RViz) ----------
    # Its output is also written to /tmp/map_lio.log for the control window.
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 8
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[map_lio] launching map_lio_bench.launch (rviz=$RVIZ_ARG) ..."
roslaunch map_lio map_lio_bench.launch bag_file:=$MAP_LIO_BAG config:=$CONFIG_CONTAINER rviz:=$RVIZ_ARG 2>&1 | tee /tmp/map_lio.log
'\'' C-m

    # ---------- PANE 3: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 14
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "=== ROS 1 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
rostopic list
echo ""
echo "--- Checking MAP_LIO output: $ODOM_TOPIC ---"
timeout 5 rostopic hz $ODOM_TOPIC 2>&1 &
echo ""
echo "--- Checking MAP_LIO output: $CLOUD_TOPIC ---"
timeout 5 rostopic hz $CLOUD_TOPIC 2>&1 &
wait
echo ""
echo "[diag] done — you can type ROS 1 commands here, e.g.:"
echo "  rostopic echo $ODOM_TOPIC"
'\'' C-m

    # ---------- Control window (window 1) ----------
    # This is the window the user attaches to; the 4 noisy panes are on window 0.
    # MAP_LIO keeps spinning after the last message, so the end of the run is
    # its "End of the bag file" line (or estimate_map exiting on an error).
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[control] waiting for MAP_LIO to process the whole bag..."
for i in $(seq 120); do pgrep -x estimate_map >/dev/null && break; sleep 1; done
while pgrep -x estimate_map >/dev/null && ! grep -q "End of the bag file" /tmp/map_lio.log 2>/dev/null; do
  sleep 2
done
if grep -q "End of the bag file" /tmp/map_lio.log 2>/dev/null; then
  echo "[control] MAP_LIO reached the end of the bag — shutting down"
else
  echo "[control] estimate_map is not running and did not reach the end of the bag — shutting down"
fi

# Let the recorder write the last messages
sleep 3

# Graceful stop: Ctrl+C to each pane, the recorder first so its bag is closed cleanly
# Pane layout: 0=roscore, 1=recorder, 2=map_lio+rviz, 3=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 2
tmux send-keys -t '"$TMUX_SESSION"':0.2 C-c
sleep 2
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
sleep 3

# Force-kill by process name
echo "[control] force-killing remaining processes..."
pkill -9 estimate_map     2>/dev/null || true
pkill -9 rviz             2>/dev/null || true
pkill -9 hector_traj      2>/dev/null || true
pkill -9 robot_state      2>/dev/null || true
pkill -9 joint_state      2>/dev/null || true
pkill -9 rosmaster        2>/dev/null || true
pkill -9 rosout           2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# The preflight check failed: nothing was recorded, and converting would pick
# up a stale recording from an earlier run.
if [[ $? -eq 42 ]]; then
  echo "=== ABORTED: input check failed, no conversion ==="
  exit 1
fi

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash
    rosrun map_lio_to_hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-MAP_LIO\" \
      \"$ODOM_TOPIC\" \
      \"$CLOUD_TOPIC\"
  "

echo "=== DONE ==="
