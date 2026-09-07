#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command g++
make -C "$ROOT" -B activity-sampler >/dev/null

fixture_root=$(mktemp -d)
trap 'rm -rf -- "$fixture_root"' EXIT

proc_path="$fixture_root/proc"
sys_path="$fixture_root/sys"
device_path="$fixture_root/devices/0000:04:00.0"
driver_path="$fixture_root/drivers/nvidia"
library_path="$fixture_root/lib"
nvml_log="$fixture_root/nvml.log"

mkdir -p \
  "$proc_path" \
  "$sys_path/class/drm/card0" \
  "$device_path/power" \
  "$driver_path" \
  "$library_path"
printf '321.50 100.00\n' >"$proc_path/uptime"
printf '0x10de\n' >"$device_path/vendor"
printf 'NVIDIA Power Fixture\n' >"$device_path/product_name"
printf 'suspended\n' >"$device_path/power/runtime_status"
ln -s "$device_path" "$sys_path/class/drm/card0/device"
ln -s "$driver_path" "$device_path/driver"

cat >"$fixture_root/fake-nvml.cpp" <<'CPP'
#include <cstdlib>
#include <fstream>

namespace {
void Log(const char *event, const char *detail = nullptr) {
  std::ofstream stream(std::getenv("NVML_TEST_LOG"), std::ios::app);
  stream << event;
  if (detail)
    stream << ' ' << detail;
  stream << '\n';
}
} // namespace

extern "C" {
struct Utilization {
  unsigned int gpu;
  unsigned int memory;
};
struct Memory {
  unsigned long long total;
  unsigned long long free;
  unsigned long long used;
};

int nvmlInitWithFlags(unsigned int flags) {
  Log(flags == 2 ? "init-no-attach" : "init-wrong-flags");
  return 0;
}
int nvmlShutdown() {
  Log("shutdown");
  return 0;
}
int nvmlDeviceGetHandleByPciBusId_v2(const char *id, void **device) {
  Log("handle", id);
  *device = reinterpret_cast<void *>(1);
  return 0;
}
int nvmlDeviceGetName(void *, char *name, unsigned int length) {
  const char value[] = "NVIDIA Awake Fixture";
  for (unsigned int index = 0; index < length && index < sizeof(value); ++index)
    name[index] = value[index];
  return 0;
}
int nvmlDeviceGetUtilizationRates(void *, Utilization *value) {
  *value = {62, 14};
  return 0;
}
int nvmlDeviceGetMemoryInfo(void *, Memory *value) {
  *value = {8589934592ULL, 6442450944ULL, 2147483648ULL};
  return 0;
}
int nvmlDeviceGetClockInfo(void *, unsigned int, unsigned int *clock) {
  *clock = 1950;
  return 0;
}
}
CPP
g++ -shared -fPIC -o "$library_path/libnvidia-ml.so.1" \
  "$fixture_root/fake-nvml.cpp"

read_gpu_frame() {
  local output_fd="$1"
  local result_name="$2"
  local line
  local -n result="$result_name"
  result=""
  while IFS= read -r -u "$output_fd" line; do
    [[ $line == $'snapshot-end\tgpus' ]] && return 0
    result+="$line"$'\n'
  done
  return 1
}

coproc GPU_READER {
  exec env \
    LD_LIBRARY_PATH="$library_path" \
    NVML_TEST_LOG="$nvml_log" \
    OMARCHY_SYSTEM_STATS_PROC_PATH="$proc_path" \
    OMARCHY_SYSTEM_STATS_SYS_PATH="$sys_path" \
    "$ROOT/activity-sampler" --activity-reader
}
gpu_reader_pid=$GPU_READER_PID
gpu_reader_input=${GPU_READER[1]}
gpu_reader_output=${GPU_READER[0]}

printf 'gpus\n' >&"$gpu_reader_input"
read_gpu_frame "$gpu_reader_output" sleeping_frame ||
  fail "GPU reader stopped while the NVIDIA device was suspended"
[[ ! -e $nvml_log ]] ||
  fail "GPU reader loaded NVML for a suspended NVIDIA device" "$(cat "$nvml_log")"
grep -Fq $'gpu\t0000:04:00.0\tNVIDIA\tnvidia\tNVIDIA Power Fixture\t-1\t-1\t-1\tunknown\t-1' \
  <<<"$sleeping_frame" ||
  fail "GPU reader did not retain static details for a suspended NVIDIA device" "$sleeping_frame"
pass "activity monitor leaves a runtime-suspended NVIDIA GPU untouched"

printf 'active\n' >"$device_path/power/runtime_status"
printf 'gpus\n' >&"$gpu_reader_input"
read_gpu_frame "$gpu_reader_output" active_frame ||
  fail "GPU reader stopped while the NVIDIA device was active"
grep -Fq $'gpu\t0000:04:00.0\tNVIDIA\tnvidia\tNVIDIA Awake Fixture\t62\t2147483648\t8589934592\tvram\t1950' \
  <<<"$active_frame" ||
  fail "GPU reader did not report NVML stats for an active NVIDIA device" "$active_frame"
expected_log=$'init-no-attach\nhandle 0000:04:00.0\nshutdown'
[[ $(cat "$nvml_log") == "$expected_log" ]] ||
  fail "GPU reader did not use no-attach NVML and release it after sampling" "$(cat "$nvml_log")"
pass "activity monitor samples an awake NVIDIA GPU and immediately releases NVML"

printf 'suspended\n' >"$device_path/power/runtime_status"
printf 'gpus\n' >&"$gpu_reader_input"
read_gpu_frame "$gpu_reader_output" resuspended_frame ||
  fail "GPU reader stopped after the NVIDIA device suspended"
exec {gpu_reader_input}>&-
wait "$gpu_reader_pid"
[[ $(cat "$nvml_log") == "$expected_log" ]] ||
  fail "GPU reader touched NVML again after the NVIDIA device suspended" "$(cat "$nvml_log")"
grep -Fq $'gpu\t0000:04:00.0\tNVIDIA\tnvidia\tNVIDIA Awake Fixture\t-1\t-1\t-1\tunknown\t-1' \
  <<<"$resuspended_frame" ||
  fail "GPU reader retained stale NVIDIA metrics after runtime suspend" "$resuspended_frame"
pass "activity monitor stops reporting live stats when NVIDIA suspends"
