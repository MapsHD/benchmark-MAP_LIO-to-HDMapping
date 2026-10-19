## Hint

Please change branch to [Bunker-DVI-Dataset-reg-1](https://github.com/MapsHD/benchmark-MAP_LIO-to-HDMapping/tree/Bunker-DVI-Dataset-reg-1) for quick experiment.

## Example Dataset:

Download the dataset from [Bunker DVI Dataset](https://charleshamesse.github.io/bunker-dvi-dataset/)

# benchmark-MAP_LIO-to-HDMapping

Runs the [MAP_LIO](https://github.com/eugeniu1994/MAP_LIO) LiDAR-inertial
odometry on a ROS 1 bag file and converts the output to an
[HDMapping](https://github.com/MapsHD/HDMapping) session.

MAP_LIO (E. Vezeteu et al.) is a single-state maximum a posteriori (MAP)
LiDAR-inertial estimator with data-driven covariances from local geometric
uncertainty. It can additionally fuse a prior airborne (ALS) map and GNSS-INS
poses; this benchmark builds and runs the LiDAR-inertial part only (no prior
map). MAP_LIO is released for academic research use only, see its repository.

## Prerequisites

- Docker
- A ROS 1 bag with a `sensor_msgs/PointCloud2` LiDAR topic and a
  `sensor_msgs/Imu` topic (ROS 2 bags are automatically converted to ROS 1
  format). MAP_LIO reads the Hesai driver's point format: `x`, `y`, `z`,
  `intensity` and a per-point `timestamp` (float64, absolute time in seconds).
  Clouds with a relative per-point `time` (float32, seconds after the header
  stamp), e.g. Livox clouds aggregated by
  [livox_bag_aggregate](https://github.com/MapsHD/livox_bag_aggregate), are
  converted to that format automatically.

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-MAP_LIO-to-HDMapping.git --recursive
cd benchmark-MAP_LIO-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t map-lio_noetic .
```

This installs:
- Ubuntu 20.04 + ROS 1 Noetic
- Eigen3, PCL, GeographicLib and the ROS packages MAP_LIO needs
- Sophus (non-templated version, the commit MAP_LIO pins)
- catkin workspace with `map_lio` and `map_lio_to_hdmapping`

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros1-map-lio.sh
./docker_session_run-ros1-map-lio.sh /path/to/input.bag /path/to/output/dir
```

Or with no arguments to use a GUI file selector (requires `zenity`).

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONFIG_FILE` | `hesai.yaml` | MAP_LIO parameter file: LiDAR/IMU topics, LiDAR-IMU extrinsics, noise, range limits. A file on the host, or the name of one shipped in the image |
| `USE_RVIZ` | `1` | RViz live view |

MAP_LIO's sensor setup lives in its parameter file. The image ships two:

| Name | Sensor |
|------|--------|
| `hesai.yaml` | MAP_LIO's own, Hesai LiDAR (`/hesai/pandar`, `/imu/data_raw`) |
| `bunker.yaml` | Livox Mid-360 with its built-in IMU (`/livox/pointcloud`, `/livox/imu`), see [overlay/config/bunker.yaml](overlay/config/bunker.yaml) |

For your own sensor, copy one of them, set `common/lid_topic`,
`common/imu_topic` and the LiDAR-IMU extrinsics, and pass it:

```bash
CONFIG_FILE=/path/to/my_sensor.yaml \
  ./docker_session_run-ros1-map-lio.sh /path/to/input.bag /path/to/output/dir
```

Before anything starts, the script checks that both topics of the parameter
file are in the bag and looks at the LiDAR point format: Hesai points are used
as they are, points with a relative per-point `time` are converted to the Hesai
format first (inside the container, the input bag is not changed), anything
else gets a warning (MAP_LIO then does not deskew the scans).

**What happens:**

The script opens a Docker container with a tmux session containing four panes
on window 0 and a `control` window (window 1, the attach target):

| Pane | Role |
|------|------|
| 0 | `roscore` |
| 1 | `rosbag record /Odometry /cloud_registered` |
| 2 | `roslaunch map_lio map_lio_bench.launch` — MAP_LIO reading your bag (+ RViz live view) |
| 3 | diagnostics — shows active topics and publishing rates |

MAP_LIO does not need `rosbag play`: it opens the bag itself and processes it
as fast as it can. When it reports the end of the bag, the control window stops
the recorder, kills all nodes and RViz, and exits tmux. A second Docker run then
converts the recorded bag into the HDMapping session format.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-MAP_LIO/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
...
session.json
trajectory_lio_0.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on MAP_LIO

MAP_LIO publishes:

| Topic | Type | Meaning |
|-------|------|---------|
| `/Odometry` | `nav_msgs/Odometry` | the 6-DoF IMU (body) pose in the `world` frame, one per scan |
| `/cloud_registered` | `sensor_msgs/PointCloud2` | the registered scan in the `world` frame, one per scan |
| `/Laser_map` | `sensor_msgs/PointCloud2` | the local map, for display |

The converter records `/Odometry` + `/cloud_registered`. MAP_LIO publishes the
registered scan only while someone subscribes to it, so the recorder is started
before MAP_LIO.

**Timestamps:** the benchmark does not change MAP_LIO's clock (no
`use_sim_time`). MAP_LIO reads the bag directly and stamps every output with the
scan's end time taken from the input messages, so the result is in bag time
without any translation.

## Contact

januszbedkowski@gmail.com
