#!/usr/bin/env bash
# Before/after scenario for adorsys/keycloak-config-cli PR #1785
# usage: scenario.sh <label> <jar>
set -euo pipefail
LABEL=$1; JAR=$2; KC=http://localhost:8080
tok() { curl -s -d client_id=admin-cli -d username=admin -d password=admin123 -d grant_type=password \
  $KC/realms/master/protocol/openid-connect/token | jq -r .access_token; }
api() { local m=$1 p=$2; shift 2; curl -s -o /dev/null -w '%{http_code}' -X "$m" -H "Authorization: Bearer $(tok)" -H 'Content-Type: application/json' "$KC/admin/realms$p" "$@"; }
groups() { curl -s -H "Authorization: Bearer $(tok)" "$KC/admin/realms/$1/groups?max=10000" | jq -r '.[].name' | sort | paste -sd, -; }
kcc() { java -jar "$JAR" --keycloak.url=$KC --keycloak.user=admin --keycloak.password=admin123 \
  --logging.level.root=WARN --logging.level.de.adorsys.keycloak.config=INFO --import.cache.enabled=false "$@" 2>&1 | grep -E 'Delete|delete|Create|group|Group|took|ERROR' || true; }

echo "===== [$LABEL] #1682: managed.group=full + remote state, state holds no group yet ====="
api DELETE /issue1682 >/dev/null || true
api POST "" -d '{"realm":"issue1682","enabled":true}' >/dev/null
api POST /issue1682/groups -d '{"name":"legacy-team-a"}' >/dev/null
api POST /issue1682/groups -d '{"name":"legacy-team-b"}' >/dev/null
echo "groups before import : $(groups issue1682)   (created by hand, not by keycloak-config-cli)"
cat > /tmp/issue1682.json <<'J'
{ "realm": "issue1682", "enabled": true, "groups": [ { "name": "app-admins" } ] }
J
kcc --import.files.locations=/tmp/issue1682.json --import.managed.group=full --import.remote-state.enabled=true
echo "groups after import  : $(groups issue1682)"
echo

echo "===== [$LABEL] #1681: group import in a realm with 3000 groups ====="
if [ "$(api GET /issue1681)" != 200 ]; then
  api POST "" -d '{"realm":"issue1681","enabled":true}' >/dev/null
  T=$(tok)
  for i in $(seq -w 1 3000); do
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
      "$KC/admin/realms/issue1681/groups" -d "{\"name\":\"existing-$i\"}" &
    (( 10#$i % 50 == 0 )) && { wait; T=$(tok); }
  done; wait
fi
echo "groups in realm      : $(curl -s -H "Authorization: Bearer $(tok)" "$KC/admin/realms/issue1681/groups/count" | jq .count)"
python3 - > /tmp/issue1681.json <<'P'
import json
print(json.dumps({"realm":"issue1681","enabled":True,"groups":[{"name":f"imported-{i:02d}"} for i in range(1,51)]}))
P
for id in $(curl -s -H "Authorization: Bearer $(tok)" "$KC/admin/realms/issue1681/groups?search=imported-&max=1000" | jq -r '.[].id'); do api DELETE /issue1681/groups/$id >/dev/null; done
echo "import file          : 50 groups (import.managed.group=no-delete)"
start=$(date +%s.%N)
java -jar "$JAR" --keycloak.url=$KC --keycloak.user=admin --keycloak.password=admin123 \
  --logging.level.root=WARN --import.files.locations=/tmp/issue1681.json --import.managed.group=no-delete \
  --import.cache.enabled=false >/dev/null 2>&1
end=$(date +%s.%N)
printf 'import duration      : %.1f s\n' "$(echo "$end - $start" | bc)"
echo
