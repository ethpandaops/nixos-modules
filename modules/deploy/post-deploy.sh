# comin's postDeploymentCommand. It records the deployment and starts the
# checks in their own units, so comin isn't blocked and a rollback isn't
# killed if comin restarts itself.
mkdir -p "$RUN_DIR" "$STATE_DIR"
jq -n \
  --arg sha "${COMIN_GIT_SHA:-}" \
  --arg ref "${COMIN_GIT_REF:-}" \
  --arg status "${COMIN_STATUS:-}" \
  --arg error "${COMIN_ERROR_MSG:-}" \
  --arg system "$(readlink -f /run/current-system)" \
  --argjson at "$(date +%s)" \
  '{$sha, $ref, $status, $error, $system, $at}' >"$RUN_DIR/deployment.json"
if [ "${COMIN_STATUS:-}" = "done" ]; then
  cp "$RUN_DIR/deployment.json" "$STATE_DIR/deployed.json"
fi
echo "deployment of ${COMIN_GIT_SHA:-?} from ${COMIN_GIT_REF:-?}: ${COMIN_STATUS:-?}"

if [ -n "$(setting .healthCheck.enable)" ]; then
  systemctl start --no-block nixhost-health-check.service
fi
systemctl start --no-block nixhost-deploy-lag.service || true
systemctl start --no-block nixhost-reboot-detect.service 2>/dev/null || true
