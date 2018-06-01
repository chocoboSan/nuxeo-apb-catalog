#!/bin/bash
set -e

SERVICE_ACCOUNT_PATH=/var/run/secrets/kubernetes.io/serviceaccount
KUBE_TOKEN=$(<${SERVICE_ACCOUNT_PATH}/token)
KUBE_NAMESPACE=$(<${SERVICE_ACCOUNT_PATH}/namespace)

STATEFULSET_NAME=$(echo "${HOSTNAME}" | sed 's/-[0-9]*$//g')
INSTANCE_ID=$(echo "${HOSTNAME}" | grep -o '[0-9]*$')

echo "Prepare stopping of Pet ${KUBE_NAMESPACE}/${HOSTNAME} of StatefulSet ${KUBE_NAMESPACE}/${STATEFULSET_NAME} instance_id ${INSTANCE_ID}"

INSTANCES_DESIRED=$(curl -s \
  --cacert ${SERVICE_ACCOUNT_PATH}/ca.crt \
  -H "Authorization: Bearer $KUBE_TOKEN" \
  "https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_PORT_443_TCP_PORT}/apis/apps/v1beta1/namespaces/${KUBE_NAMESPACE}/statefulsets/${STATEFULSET_NAME}/status" | jq -r '.spec.replicas')

echo "Desired instance count is ${INSTANCES_DESIRED}"

if [ "${INSTANCE_ID}" -lt "${INSTANCES_DESIRED}" ]; then
  echo "No data migration needed"
  exit 0
fi

echo "Prepare to migrate data of the node"

NODE_STATS=$(curl -s -XGET 'http://localhost:9200/_nodes/stats')
NODE_IP=$(echo "${NODE_STATS}" | jq -r ".nodes[] | select(.name==\"${HOSTNAME}\") | .host")

echo "Move all data from node ${NODE_IP}"

curl -s -XPUT localhost:9200/_cluster/settings -d "{
  \"transient\" :{
      \"cluster.routing.allocation.exclude._ip\" : \"${NODE_IP}\"
  }
}"
echo

echo "Wait for node to become empty"
DOC_COUNT=$(echo "${NODE_STATS}" | jq ".nodes[] | select(.name==\"${HOSTNAME}\") | .indices.docs.count")
while [ "${DOC_COUNT}" -gt 0 ]; do
  NODE_STATS=$(curl -s -XGET 'http://localhost:9200/_nodes/stats')
  DOC_COUNT=$(echo "${NODE_STATS}" | jq -r ".nodes[] | select(.name==\"${HOSTNAME}\") | .indices.docs.count")
  echo "Node contains ${DOC_COUNT} documents"
  sleep 1
done

echo "Wait for node shards to become empty"
SHARD_STATS=$(curl -s -XGET 'http://localhost:9200/_cat/shards?format=json')
SHARD_COUNT=$(echo "${SHARD_STATS}" | jq "[.[] | select(.node==\"${HOSTNAME}\")] | length")
while [ "${SHARD_COUNT}" -gt 0 ]; do
  SHARD_STATS=$(curl -s -XGET 'http://localhost:9200/_cat/shards?format=json')
  SHARD_COUNT=$(echo "${SHARD_STATS}" | jq "[.[] | select(.node==\"${HOSTNAME}\")] | length")
  echo "Node contains ${SHARD_COUNT} shards"
  sleep 1
done

echo "Node clear to shutdown"