#!/bin/bash
#******************************************************************************
# Licensed Materials - Property of IBM
# (c) Copyright IBM Corporation 2020. All Rights Reserved.
#
# Note to U.S. Government Users Restricted Rights:
# Use, duplication or disclosure restricted by GSA ADP Schedule
# Contract with IBM Corp.
#******************************************************************************

#******************************************************************************
# PREREQUISITES:
#   - Logged into cluster on the OC CLI (https://docs.openshift.com/container-platform/4.4/cli_reference/openshift_cli/getting-started-cli.html)
#
# PARAMETERS:
#   -n : <namespace> (string), Defaults to "fhir-dev"
#   -r : <release_name> (string), Defaults to "mq-fhir"
#   -i : <image_name> (string)
#   -q : <qm_name> (string), Defaults to "QMGR"
#   -z : <tracing_namespace> (string), Defaults to "namespace"
#   -t : <tracing_enabled> (boolean), optional flag to enable tracing, Defaults to false
#
# USAGE:
#   With defaults values
#     ./release-mq.sh
#
#   Overriding the namespace and release-name
#     ./release-mq -n cp4i -r mq-demo -i image-registry.openshift-image-registry.svc:5000/cp4i/mq-ddd -q mq-qm

function divider() {
  echo -e "\n-------------------------------------------------------------------------------------------------------------------\n"
}

function usage() {
  echo "Usage: $0 -n <namespace> -r <release_name> -i <image_name> -q <qm_name> -z <tracing_namespace> [-t]"
  divider
  exit 1
}

tick="\xE2\x9C\x85"
cross="\xE2\x9D\x8C"
namespace="fhir-dev"
release_name="mq-fhir"
qm_name="QMGR"
tracing_namespace=""
tracing_enabled="false"
CURRENT_DIR=$(dirname $0)
echo "Current directory: $CURRENT_DIR"
echo "Namespace: $namespace"

while getopts "n:r:i:q:z:t" opt; do
  case ${opt} in
  n)
    namespace="$OPTARG"
    ;;
  r)
    release_name="$OPTARG"
    ;;
  i)
    image_name="$OPTARG"
    ;;
  q)
    qm_name="$OPTARG"
    ;;
  z)
    tracing_namespace="$OPTARG"
    ;;
  t)
    tracing_enabled=true
    ;;
  \?)
    usage
    ;;
  esac
done

# when called from install.sh
if [ "$tracing_enabled" == "true" ]; then
  if [ -z "$tracing_namespace" ]; then tracing_namespace=${namespace}; fi
else
  # assigning value to tracing_namespace b/c empty values causes CR to throw an error
  tracing_namespace=${namespace}
fi

echo "[INFO] tracing is set to $tracing_enabled"

# if [[ "$release_name" =~ "ddd" ]]; then
#   numberOfContainers=3
# elif [[ "$release_name" =~ "eei" ]]; then
#   numberOfContainers=1
# fi

if [ -z $image_name ]; then

  cat <<EOF | oc apply -f -
apiVersion: mq.ibm.com/v1beta1
kind: QueueManager
metadata:
  name: ${release_name}
  namespace: ${namespace}
spec:
  license:
    accept: true
    license: L-RJON-BN7PN3
    use: NonProduction
  queueManager:
    name: ${qm_name}
    storage:
      queueManager:
        type: ephemeral
  template:
    pod:
      containers:
        - env:
            - name: MQSNOAUT
              value: 'yes'
          name: qmgr
  version: 9.2.0.0-r1
  web:
    enabled: true
  tracing:
    enabled: ${tracing_enabled}
    namespace: ${tracing_namespace}
EOF
  if [[ "$?" != "0" ]]; then
    echo -e "$cross [ERROR] Failed to apply QueueManager CR"
    exit 1
  fi

else

  # --------------------------------------------------- FIND IMAGE TAG ---------------------------------------------------

  divider

  imageTag=${image_name##*:}

  echo "INFO: Image tag found for '$release_name' is '$imageTag'"
  echo "INFO: Image is '$image_name'"
  echo "INFO: Release name is: '$release_name'"

  if [[ -z "$imageTag" ]]; then
    echo "ERROR: Failed to extract image tag from the end of '$image_name'"
    exit 1
  fi


  cat <<EOF | oc apply -f -
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: create-fhir-queues-mqsc
  namespace: $namespace
data:
  create-fhir-queues.mqsc: |-
    DEFINE QLOCAL('FHIR.ALLERGY.RECEIVEQ')
    DEFINE QLOCAL('FHIR.OBSERVATION.RECEIVEQ')
    DEFINE QLOCAL('FHIR.PATIENT.RECEIVEQ')
    DEFINE QLOCAL('PATIENT.ALLERGY.REPLYQ')
    DEFINE QLOCAL('PATIENT.DATA.REPLYQ')
    DEFINE QLOCAL('PATIENT.OBSERVATION.REPLYQ')
    DEFINE QLOCAL('HTTPS.RESPONSE.ACK')
    DEFINE QLOCAL('HL7.ALLERGY.SENDQ')
    DEFINE QLOCAL('HL7.EXCEPTIONQ')
    DEFINE QLOCAL('HL7.OBSERVATION.SENDQ')
    DEFINE QLOCAL('HL7.PATIENT.SENDQ')
    DEFINE QLOCAL('HL7.WRONG.SEGMENTQ')
EOF
  if [[ "$?" != "0" ]]; then
    echo -e "$cross [ERROR] Failed to apply ConfigMap for MQSC"
    exit 1
  fi

  echo -e "INFO: Going ahead to apply the CR for '$release_name'"

  divider

  cat <<EOF | oc apply -f -
apiVersion: mq.ibm.com/v1beta1
kind: QueueManager
metadata:
  name: ${release_name}
  namespace: ${namespace}
spec:
  license:
    accept: true
    license: L-RJON-BN7PN3
    use: NonProduction
  queueManager:
    image: ${image_name}
    imagePullPolicy: Always
    name: ${qm_name}
    storage:
      queueManager:
        type: ephemeral
    mqsc:
      - configMap:
          items:
            - create-fhir-queues.mqsc
          name: create-fhir-queues-mqsc
  template:
    pod:
      containers:
        - env:
            - name: MQSNOAUT
              value: 'yes'
          name: qmgr
  version: 9.2.0.0-r1
  web:
    enabled: true
  #securityContext:
  #  initVolumeAsRoot: false
  #  #StorageClass Consideration & Security Context
  #  #https://www.ibm.com/support/knowledgecenter/SSFKSJ_9.2.0/com.ibm.mq.ctr.doc/ctr_storage.htm
  #  supplementalGroups: 
  #    - 99
  tracing:
    enabled: ${tracing_enabled}
    namespace: ${tracing_namespace}
EOF
  if [[ "$?" != "0" ]]; then
    echo -e "$cross [ERROR] Failed to apply QueueManager CR"
    exit 1
  fi

  
 
