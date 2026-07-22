#!/usr/bin/env bash
set -euo pipefail

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
: "${ETALIEN_TOKEN:?ETALIEN_TOKEN is required}"
: "${ETALIEN_DVC:?ETALIEN_DVC is required}"

app_apk="${1:?app APK path is required}"
test_apk="${2:?test APK path is required}"
max_ads="${MAX_ADS:-9}"
wait_seconds="${ETALIEN_MATRIX_WAIT_SECONDS:-1500}"
poll_seconds="${ETALIEN_MATRIX_POLL_SECONDS:-20}"
history_name="${ETALIEN_RESULTS_HISTORY:-etalien-daily-pc-rewards}"

# Keep the daily run bounded to two Spark virtual-device tests. The second
# target differs in both virtual hardware and Android version, and is used only
# after Test Lab reports an infrastructure failure before the app can run.
targets=(
  "MediumPhone.arm:34"
  "SmallPhone.arm:33"
)

submit_matrix() {
  local target="$1"
  local attempt="$2"
  local model version log_file matrix_id

  IFS=: read -r model version <<<"$target"
  log_file="testlab-build/submit-${attempt}.log"

  if ! gcloud firebase test android run \
    --project "$GCP_PROJECT_ID" \
    --type instrumentation \
    --app "$app_apk" \
    --test "$test_apk" \
    --device "model=$model,version=$version,locale=zh_CN,orientation=portrait" \
    --timeout 25m \
    --environment-variables \
      "ETALIEN_TOKEN=$ETALIEN_TOKEN,ETALIEN_DVC=$ETALIEN_DVC,ETALIEN_MAX_ADS=$max_ads" \
    --results-history-name "$history_name" \
    --client-details "matrixLabel=daily-attempt-$attempt-$model-api$version" \
    --no-auto-google-login \
    --no-performance-metrics \
    --async \
    --quiet >"$log_file" 2>&1; then
    cat "$log_file" >&2
    return 20
  fi

  cat "$log_file" >&2
  matrix_id="$(sed -n 's/.*Test \[\(matrix-[^]]*\)\] has been created.*/\1/p' "$log_file" | tail -n 1)"
  if [[ -z "$matrix_id" ]]; then
    echo "Test Lab submission succeeded but its matrix id was not found." >&2
    return 21
  fi

  printf '%s\n' "$matrix_id"
}

wait_for_matrix() {
  local matrix_id="$1"
  local deadline=$((SECONDS + wait_seconds))
  local access_token json matrix_state execution_state outcome error messages

  while (( SECONDS < deadline )); do
    access_token="$(gcloud auth print-access-token)"
    json="$(curl --fail --silent --show-error \
      -H "Authorization: Bearer $access_token" \
      -H "x-goog-user-project: $GCP_PROJECT_ID" \
      "https://testing.googleapis.com/v1/projects/$GCP_PROJECT_ID/testMatrices/$matrix_id")"

    matrix_state="$(jq -r '.state // ""' <<<"$json")"
    execution_state="$(jq -r '.testExecutions[0].state // ""' <<<"$json")"
    outcome="$(jq -r '.outcomeSummary // ""' <<<"$json")"
    error="$(jq -r '.testExecutions[0].testDetails.errorMessage // ""' <<<"$json")"
    messages="$(jq -r '[.testExecutions[0].testDetails.progressMessages[]?] | join(" | ")' <<<"$json")"

    echo "Matrix $matrix_id: matrix=$matrix_state execution=$execution_state outcome=${outcome:-pending}"
    if [[ -n "$messages" ]]; then
      echo "Matrix progress: $messages"
    fi

    if [[ "$matrix_state" == "FINISHED" ]]; then
      if [[ "$execution_state" == "FINISHED" ]]; then
        # This custom instrumentation runner can be summarized by Test Lab as
        # FAILURE even after the device ran and returned its reward bundle.
        # A finished device execution is therefore the terminal success signal.
        echo "The device execution finished; no duplicate matrix will be submitted."
        return 0
      fi

      if [[ "$execution_state" == "ERROR" ]] &&
        { [[ "$error" == *"Internal System Error"* ]] || [[ "$messages" == *"Infrastructure error"* ]]; }; then
        echo "Test Lab infrastructure failed before the app ran: ${error:-unknown error}" >&2
        return 10
      fi

      echo "Matrix finished without a usable device execution: ${error:-$outcome}" >&2
      return 12
    fi

    sleep "$poll_seconds"
  done

  echo "Matrix $matrix_id is still active after ${wait_seconds}s; leaving it running without a duplicate." >&2
  return 11
}

for index in "${!targets[@]}"; do
  attempt=$((index + 1))
  target="${targets[$index]}"
  echo "Submitting Spark ARM matrix attempt $attempt/${#targets[@]} on $target"

  if matrix_id="$(submit_matrix "$target" "$attempt")"; then
    :
  else
    result=$?
    exit "$result"
  fi
  echo "Submitted matrix: $matrix_id"

  if wait_for_matrix "$matrix_id"; then
    exit 0
  else
    result=$?
  fi

  if [[ "$result" == 10 && "$attempt" -lt "${#targets[@]}" ]]; then
    echo "Retrying once on the fallback ARM target."
    continue
  fi

  if [[ "$result" == 11 ]]; then
    # The existing matrix may still complete and credit rewards. Do not create
    # another concurrent matrix against the same account.
    exit 0
  fi

  exit "$result"
done
