#!/bin/bash

# Copyright 2019 Nextdoor.com, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

###############################################################################
# Helper Functions                                                            #
###############################################################################

START_TIME=0
END_TIME=0
FAILED=0
PROFILE_MEM_THRESHOLD=5
PROFILE_CPU_THRESHOLD=50

log() {
  dt=$(date -u '+%F %T')
  echo "[ $BATS_TEST_DESCRIPTION | $dt ]  ${1}"
}

_check_container() {
  running=$(docker inspect -f "{{.State.Running}}" $1)

  if [ "$running" != "true" ]; then
    log "ERROR - $1 container has died prematurely"
    docker logs $1
    exit 1
  fi
}

_startup() {
  FAILED=0

  log "Running docker-compose down"
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose down

  log "Running docker-compose build"
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose build

  log "Running docker-compose up"
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose up -d

  log "Checking that containers are running..."
  sleep 5

  _check_container postgres
  _check_container kinesis
  _check_container bifrost

  log "Containers are running!"
}

_begin_timer() {
  START_TIME=$(date +%s)
}

_end_timer() {
  END_TIME=$(date +%s)
}

_write_junit_xml() {
  TOTAL_TIME=$((END_TIME-START_TIME))
  mkdir -p "test_output/$BATS_TEST_DESCRIPTION"
  cat >"test_output/$BATS_TEST_DESCRIPTION/junit.xml" <<EOL
<?xml version="1.0" ?>
<testsuites>
    <testsuite errors="0" failures="$FAILED" name="pg-bifrost integration tests" tests="1">
        <testcase classname="pgbifrost" name="$BATS_TEST_DESCRIPTION" time="$TOTAL_TIME">
            <system-out>
            </system-out>
            <system-err>
            </system-err>
        </testcase>
    </testsuite>
</testsuites>
EOL
}

_clean() {
  log "Cleaning up previous test run output"
  rm -f ./tests/"$BATS_TEST_DESCRIPTION"/output/*
  rm -f ./tests/"$BATS_TEST_DESCRIPTION"/perf_output/*
}

_insert_data() {
  log "Waiting for replication slot to be created"
  grep -q 'START_REPLICATION SLOT' <(docker logs --follow postgres 2>&1)
  pkill -f "docker logs.*" || true

  log "Inserting test data into postgres"

  # Launch inserts
  for file in ./tests/"$BATS_TEST_DESCRIPTION"/input/*; do
    file=$(echo "$file" | cut -d "/" -f 5)

    log "Loading $file"
    TEST_NAME=$BATS_TEST_DESCRIPTION docker exec -u postgres -t postgres wait_ready.sh /usr/local/bin/psql -f "/input/$file" &
  done
}

# Retry logic
# https://unix.stackexchange.com/a/137639
function _fail {
  echo $1 >&2
  exit 1
}

function _retry {
  local n=1
  local max=12
  local delay=1

  log "Inside retry"

  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        log "Command failed. Attempt $n/$max:"
        sleep $delay;
      else
        _fail "The command has failed after $n attempts."
      fi
    }
  done
}

_check_lsn() {
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose kill -s HUP postgres
  confirmed_flush_lsn=$(TEST_NAME=$BATS_TEST_DESCRIPTION docker exec -u postgres -t postgres /usr/local/bin/psql -c "select confirmed_flush_lsn from pg_replication_slots" -P "footer=off" -t | head -n1 | awk '{$1=$1};1' | cut -c -9)
  confirmed_flush_lsn_int=$(echo $confirmed_flush_lsn | cut -c 3- | xargs echo ibase=16\; | bc)

  latest_lsn=$(cat tests/$BATS_TEST_DESCRIPTION/output/* | jq '.lsn' -r | sort | tail -n1)
  latest_lsn_int=$(echo $latest_lsn | cut -c 3- | xargs echo ibase=16\; | bc)

  log "Confirmed flush LSN: '$confirmed_flush_lsn'  /  $confirmed_flush_lsn_int"
  log "Latest LSN in output: '$latest_lsn'  /  $latest_lsn_int"

  if [ "$confirmed_flush_lsn_int" -lt "$latest_lsn_int" ]; then
   log "bifrost did not update the replication slot status as LSN in output is greater than that of the LSN on the replication slot in Postgres"
   return 1
  fi

  return 0
}

_verify() {
  log "Verifying test output"
  for file in ./tests/"$BATS_TEST_DESCRIPTION"/golden/*; do
    file=$(echo "$file" | cut -d "/" -f 5)
    log "Verifying against golden file $file"
    log "Sort: $SORT"

    if [ "$SORT" == "false" ]; then
        output=$(diff <(cat "./tests/$BATS_TEST_DESCRIPTION/golden/$file") <(cat "./tests/$BATS_TEST_DESCRIPTION/output/$file" | jq 'del(.lsn, .time)' -c -M) || true)
    else
        output=$(diff <(cat "./tests/$BATS_TEST_DESCRIPTION/golden/$file") <(sort "./tests/$BATS_TEST_DESCRIPTION/output/$file" | jq 'del(.lsn, .time)' -c -M) || true)
    fi

    if ! $output; then
      ret_code=$?
      FAILED=1
      log "Only showing first 20 diff lines"
      echo "$output" | head -n 20
      exit $ret_code
    fi
  done

  log "Verifying replication slot status"
  FAILED=1
  _retry _check_lsn
  FAILED=0
}

_profile() {
  if [ ! -d "./tests/$BATS_TEST_DESCRIPTION/perf_base" ]; then
    log "Skipping profiling as ./tests/$BATS_TEST_DESCRIPTION/perf_base does not exist"
    return
  fi

  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose down

  log "Comparing Memory Profile"
  memprofile=$(go tool pprof -normalize -top -show github.com/Nextdoor -diff_base tests/$BATS_TEST_DESCRIPTION/perf_base/mem.pprof ../target/pg-bifrost tests/$BATS_TEST_DESCRIPTION/perf_output/mem.pprof.stop | tail -n +9 | tr -s ' ' | awk '{$1=$1};1' | cut -d ' ' -f5- | egrep -v vendor/gopkg.in/Nextdoor/cli)
  memory_leak=false
  while read -r line; do
    percent=$(echo $line | cut -d ' ' -f1 | rev | cut -c 2- | rev)
    if [[ $(bc <<< "$PROFILE_MEM_THRESHOLD < $percent") -eq 1 ]]; then
      log "Found potential memory leak: $line"
      memory_leak=true
    fi
  done <<< "$memprofile"

  log "Comparing CPU Profile"
  cpuprofile=$(go tool pprof -normalize -top -show github.com/Nextdoor -diff_base tests/$BATS_TEST_DESCRIPTION/perf_base/cpu.pprof tests/$BATS_TEST_DESCRIPTION/perf_output/cpu.pprof | tail -n +10 | tr -s ' ' | awk '{$1=$1};1' | cut -d ' ' -f5-)
  cpu_hot=false
  while read -r line; do
    percent=$(echo $line | cut -d ' ' -f1 | rev | cut -c 2- | rev)
    if [[ $(bc <<< "$PROFILE_CPU_THRESHOLD < $percent") -eq 1 ]]; then
      log "Found potential cpu hot spot: $line"
      cpu_hot=true
    fi
  done <<< "$cpuprofile"

  if [ "$memory_leak" = true ] || [ "$cpu_hot" = true ]; then
    log "Failed due to potential performance regression"
    exit 1
  fi
}

_wait() {
  log "Waiting for test to finish"
  grep -q 'Records read' <(docker logs --follow kinesis-poller 2>&1)
  pkill -f "docker logs.*" || true
}

teardown() {
  _end_timer

  # Print current state of the ledger for debugging
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose kill -s USR2 bifrost
  sleep 5
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose logs bifrost

  log "Running docker-compose down"
  TEST_NAME=$BATS_TEST_DESCRIPTION docker-compose down

  _write_junit_xml
}

do_test() {
  _clean
  _startup
  _begin_timer
  _insert_data
  _wait
  _verify
  _profile
}
