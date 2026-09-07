#!/bin/bash

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for test_file in \
  activity-test.sh \
  activity-details-test.sh \
  activity-native-test.sh \
  activity-nvidia-power-test.sh \
  activity-privilege-test.sh \
  activity-process-action-test.sh; do
  "$root/test/$test_file"
done
