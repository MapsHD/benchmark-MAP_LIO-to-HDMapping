#!/usr/bin/env python3
"""Prepare the input bag for the MAP_LIO benchmark run.

1. Preflight: MAP_LIO reads the LiDAR and IMU topics named in its parameter
   file (common/lid_topic, common/imu_topic) straight from the bag. If either
   is missing it processes nothing and the run records no output, so the run
   is stopped first (exit code 42, the run script then skips the conversion).

2. Point format: MAP_LIO reads the Hesai driver's point format, x, y, z,
   intensity, a float64 absolute per-point 'timestamp' [s] and a uint16
   'ring', and uses the timestamps to deskew each scan.
   - Hesai format: the bag is used as it is.
   - Relative per-point float32 'time' [s] after the header stamp (e.g. Livox
     clouds aggregated by livox_bag_aggregate, like the Bunker DVI -pc.bag):
     the LiDAR topic is rewritten in the Hesai format into <output_bag>,
     with timestamp = header stamp + time and ring = 'line' (0 if absent),
     non-finite points dropped and points ordered by time, as the Hesai
     driver delivers them. The IMU (and GNSS) topics are copied unchanged,
     header stamps and bag times are kept, so the result stays in bag time.
   - Anything else: warning only, MAP_LIO then gives every point the same
     time and does not deskew.

Usage: map_lio_input.py <parameter_file.yaml> <input.bag> <output_bag>
<output_bag> is written only when the points are converted.
"""

import sys

import numpy as np
import rosbag
import yaml
from sensor_msgs.msg import PointCloud2, PointField

FLOAT32, FLOAT64, UINT16 = 7, 8, 4  # sensor_msgs/PointField datatypes
NUMPY_TYPES = {1: 'i1', 2: 'u1', 3: 'i2', 4: 'u2', 5: 'i4', 6: 'u4', 7: 'f4', 8: 'f8'}

# hesai_ros::Point as MAP_LIO declares it (include/point_definitions.hpp):
# x, y, z (+ padding), intensity, double timestamp, uint16 ring, 16-byte aligned.
HESAI_DTYPE = np.dtype({'names': ['x', 'y', 'z', 'intensity', 'timestamp', 'ring'],
                        'formats': ['<f4', '<f4', '<f4', '<f4', '<f8', '<u2'],
                        'offsets': [0, 4, 8, 16, 24, 32],
                        'itemsize': 48})
HESAI_FIELDS = [PointField('x', 0, FLOAT32, 1), PointField('y', 4, FLOAT32, 1),
                PointField('z', 8, FLOAT32, 1), PointField('intensity', 16, FLOAT32, 1),
                PointField('timestamp', 24, FLOAT64, 1), PointField('ring', 32, UINT16, 1)]


def cloud_array(msg):
    dtype = np.dtype({'names': [f.name for f in msg.fields],
                      'formats': ['<' + NUMPY_TYPES[f.datatype] for f in msg.fields],
                      'offsets': [f.offset for f in msg.fields],
                      'itemsize': msg.point_step})
    return np.frombuffer(msg.data, dtype, count=msg.width * msg.height)


def to_hesai(msg):
    a = cloud_array(msg)
    keep = np.isfinite(a['x']) & np.isfinite(a['y']) & np.isfinite(a['z'])
    a = a[keep]
    a = a[np.argsort(a['time'], kind='stable')]

    out = np.zeros(len(a), HESAI_DTYPE)
    out['x'], out['y'], out['z'] = a['x'], a['y'], a['z']
    if 'intensity' in a.dtype.names:
        out['intensity'] = a['intensity']
    out['timestamp'] = msg.header.stamp.to_sec() + a['time'].astype(np.float64)
    if 'line' in a.dtype.names:
        out['ring'] = a['line']

    cloud = PointCloud2()
    cloud.header = msg.header
    cloud.height, cloud.width = 1, len(out)
    cloud.fields = HESAI_FIELDS
    cloud.is_bigendian = False
    cloud.point_step = HESAI_DTYPE.itemsize
    cloud.row_step = cloud.point_step * cloud.width
    cloud.is_dense = True
    cloud.data = out.tobytes()
    return cloud


def main():
    config_path, bag_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        with open(config_path) as f:
            common = yaml.safe_load(f)["common"]
    except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
        print(f"[input] ERROR: cannot read common/ topics from parameter file {config_path}: {e}")
        sys.exit(42)
    lid_topic, imu_topic = common["lid_topic"], common["imu_topic"]
    gnss_topic = common.get("gnss_topic", "")
    print(f"[input] parameter file: {config_path}")
    print(f"[input] LiDAR topic: {lid_topic}  IMU topic: {imu_topic}")

    bag = rosbag.Bag(bag_path)
    topics = bag.get_type_and_topic_info().topics

    ok = True
    for name, msg_type in ((lid_topic, "sensor_msgs/PointCloud2"), (imu_topic, "sensor_msgs/Imu")):
        info = topics.get(name)
        if info is None or info.msg_type != msg_type:
            found = info.msg_type if info else "not in the bag"
            print(f"[input] ERROR: {name} must be {msg_type} ({found}).")
            ok = False
        else:
            print(f"[input] {name}: {info.message_count} msgs ({msg_type})")
    if not ok:
        for msg_type in ("sensor_msgs/PointCloud2", "sensor_msgs/Imu"):
            names = [t for t, i in topics.items() if i.msg_type == msg_type]
            print(f"[input] {msg_type} topics in this bag: {', '.join(names) or '(none)'}")
        print("[input] Set common/lid_topic and common/imu_topic in the parameter file (CONFIG_FILE).")
        sys.exit(42)

    _, first, _ = next(bag.read_messages(topics=[lid_topic]))
    fields = {f.name: f.datatype for f in first.fields}
    if fields.get("timestamp") == FLOAT64:
        print("[input] Hesai point format (float64 per-point 'timestamp'), bag used as it is")
        bag.close()
        return
    if fields.get("time") != FLOAT32:
        print(f"[input] WARNING: {lid_topic} has neither a float64 'timestamp' nor a float32 'time' "
              f"per-point field (fields: {', '.join(fields)}). MAP_LIO reads the Hesai point "
              "format; without per-point time the scans are not deskewed.")
        bag.close()
        return

    copy_topics = [t for t in (imu_topic, gnss_topic) if t and t in topics]
    print(f"[input] relative per-point float32 'time' found: converting {lid_topic} to the Hesai "
          f"point format into {output_path} (copying {', '.join(copy_topics)})")
    n_clouds = 0
    with rosbag.Bag(output_path, 'w') as out:
        for topic, msg, t in bag.read_messages(topics=[lid_topic] + copy_topics, raw=True):
            if topic == lid_topic:
                cloud = PointCloud2()
                cloud.deserialize(msg[1])
                out.write(topic, to_hesai(cloud), t)
                n_clouds += 1
                if n_clouds % 500 == 0:
                    print(f"[input]   {n_clouds} clouds converted")
            else:
                out.write(topic, msg, t, raw=True)
    bag.close()
    print(f"[input] {n_clouds} clouds converted")


if __name__ == "__main__":
    main()
