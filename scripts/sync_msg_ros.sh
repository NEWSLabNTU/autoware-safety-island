#!/usr/bin/env bash
# Copyright (c) 2026, NEWSLab NTU.
# SPDX-License-Identifier: Apache-2.0
#
# Phase 1B sync — fetch upstream ROS 2 Humble .msg sources for the
# ASI nano-ros migration and stage them under
#   actuation_module/src/autoware/autoware_msgs/msg_ros/<pkg>/msg/
#
# Maintainer-only. NOT run in CI. Run on a Linux host with network
# access + git installed; output diff lands in the working tree for
# review.
#
# After a successful run:
#   1. Inspect the diff under msg_ros/ for any unexpected upstream
#      changes since the last sync.
#   2. Update docs/MSG_PROVENANCE.md with the resolved SHAs printed
#      at the end of this script.
#   3. Commit the staged tree.
#
# Per-package pins live in the PACKAGES table below. Bumping a pin =
# edit the tag/branch column + re-run this script + review diff.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DEST="${ROOT}/actuation_module/src/autoware/autoware_msgs/msg_ros"
TMP="$(mktemp -d -t asi-msg-sync-XXXXXX)"
trap "rm -rf ${TMP}" EXIT

# -----------------------------------------------------------------------------
# Per-package source table
# -----------------------------------------------------------------------------
# Columns:
#   1. local-pkg-name     (under msg_ros/<pkg>/)
#   2. upstream repo      (org/repo)
#   3. revision           (tag or branch — script records resolved SHA)
#   4. src-subdir-in-repo (contains msg/ + package.xml)
#   5. .msg files (space-separated, no extension stripping)
#
# Keep order topologically — pkgs that depend on others later in the
# list will not be referenced because each call is self-contained.
# -----------------------------------------------------------------------------
PACKAGES=(
    "builtin_interfaces|ros2/rcl_interfaces|1.2.1|builtin_interfaces|Time.msg Duration.msg"
    "std_msgs|ros2/common_interfaces|4.2.4|std_msgs|Header.msg"
    "geometry_msgs|ros2/common_interfaces|4.2.4|geometry_msgs|Point.msg Vector3.msg Quaternion.msg Pose.msg PoseStamped.msg PoseArray.msg PoseWithCovariance.msg PoseWithCovarianceStamped.msg Twist.msg TwistStamped.msg TwistWithCovariance.msg TwistWithCovarianceStamped.msg Accel.msg AccelStamped.msg AccelWithCovariance.msg AccelWithCovarianceStamped.msg Transform.msg TransformStamped.msg QuaternionStamped.msg Vector3Stamped.msg"
    "nav_msgs|ros2/common_interfaces|4.2.4|nav_msgs|Odometry.msg"
    "autoware_perception_msgs|autowarefoundation/autoware_msgs|1.3.0|autoware_perception_msgs|PredictedPath.msg"
    "autoware_vehicle_msgs|autowarefoundation/autoware_msgs|1.3.0|autoware_vehicle_msgs|SteeringReport.msg VelocityReport.msg"
    "autoware_planning_msgs|autowarefoundation/autoware_msgs|1.3.0|autoware_planning_msgs|Trajectory.msg TrajectoryPoint.msg Path.msg PathPoint.msg"
    "autoware_control_msgs|autowarefoundation/autoware_msgs|1.3.0|autoware_control_msgs|Control.msg Lateral.msg Longitudinal.msg ControlHorizon.msg"
    "autoware_adapi_v1_msgs|autowarefoundation/autoware_adapi_msgs|1.3.0|autoware_adapi_v1_msgs/operation_mode|OperationModeState.msg"
    "tier4_debug_msgs|tier4/tier4_autoware_msgs|tier4/universe|tier4_debug_msgs|Float32Stamped.msg Float64Stamped.msg Float32MultiArrayStamped.msg Float64MultiArrayStamped.msg MultiArrayLayout.msg MultiArrayDimension.msg ProcessingTimeNode.msg ProcessingTimeTree.msg"
)

# -----------------------------------------------------------------------------

declare -a RESOLVED

fetch_pkg() {
    local pkg=$1 repo=$2 rev=$3 srcdir=$4 files=$5
    local checkout_dir="${TMP}/${pkg}"

    echo "=== ${pkg} (${repo} @ ${rev}) ==="
    git clone --quiet --filter=blob:none --no-checkout \
        "https://github.com/${repo}.git" "${checkout_dir}"
    git -C "${checkout_dir}" sparse-checkout init --cone >/dev/null
    git -C "${checkout_dir}" sparse-checkout set "${srcdir}" >/dev/null
    git -C "${checkout_dir}" checkout --quiet "${rev}"

    local sha
    sha="$(git -C "${checkout_dir}" rev-parse HEAD)"
    RESOLVED+=("${pkg}|${repo}|${rev}|${sha}")

    install -d "${DEST}/${pkg}/msg"
    for f in ${files}; do
        local src="${checkout_dir}/${srcdir}/msg/${f}"
        if [[ ! -f "${src}" ]]; then
            # Some upstream packages nest msg/ deeper (e.g. adapi
            # OperationModeState lives under operation_mode/msg/). The
            # ${srcdir} entry above already targets that subdir, but
            # double-check.
            echo "  MISSING: ${src}" >&2
            return 1
        fi
        cp "${src}" "${DEST}/${pkg}/msg/${f}"
        echo "  + ${pkg}/msg/${f}"
    done
}

# -----------------------------------------------------------------------------
# Run sync
# -----------------------------------------------------------------------------
for entry in "${PACKAGES[@]}"; do
    IFS='|' read -r pkg repo rev srcdir files <<<"${entry}"
    fetch_pkg "${pkg}" "${repo}" "${rev}" "${srcdir}" "${files}"
done

# -----------------------------------------------------------------------------
# Apply ASI-local patches
# -----------------------------------------------------------------------------
TRAJ="${DEST}/autoware_planning_msgs/msg/Trajectory.msg"
if [[ -f "${TRAJ}" ]]; then
    # Add the [<=250] upper bound that ASI requires for static memory
    # sizing on the controller path. Fail loud if the upstream form
    # changed and the substitution doesn't fire.
    sed -i 's|TrajectoryPoint\[\] points|TrajectoryPoint[<=250] points|' "${TRAJ}"
    if ! grep -q 'TrajectoryPoint\[<=250\] points' "${TRAJ}"; then
        echo "ERROR: Trajectory.msg bound patch failed — upstream form changed?" >&2
        exit 1
    fi
    echo "+ Patched Trajectory.msg: points -> [<=250]"
fi

# -----------------------------------------------------------------------------
# Resolved-SHA report (paste into docs/MSG_PROVENANCE.md)
# -----------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "Sync complete. Update docs/MSG_PROVENANCE.md with these rows:"
echo "================================================================"
printf "| %-26s | %-44s | %-20s | %-40s |\n" \
    "Package" "Upstream repo" "Tag/branch" "Pinned SHA"
printf "|%s|%s|%s|%s|\n" \
    "$(printf -- '-%.0s' {1..28})" \
    "$(printf -- '-%.0s' {1..46})" \
    "$(printf -- '-%.0s' {1..22})" \
    "$(printf -- '-%.0s' {1..42})"
for r in "${RESOLVED[@]}"; do
    IFS='|' read -r pkg repo rev sha <<<"${r}"
    printf "| %-26s | %-44s | %-20s | %-40s |\n" \
        "${pkg}" "${repo}" "${rev}" "${sha}"
done
echo ""
echo "Local patches:"
echo "  - autoware_planning_msgs/msg/Trajectory.msg: points bounded to [<=250]"
