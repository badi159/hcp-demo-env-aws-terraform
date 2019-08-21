#!/usr/bin/env bash

set -e # abort on error
set -u # abort on undefined variable

###############################################################################
# Set variables from terraform output
###############################################################################

LOCAL_SSH_PUB_KEY_PATH=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["ssh_pub_key_path"]["value"])')
LOCAL_SSH_PRV_KEY_PATH=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["ssh_prv_key_path"]["value"])')

CLIENT_CIDR_BLOCK=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["client_cidr_block"]["value"])') 

EPIC_RPM_DL_URL=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["epic_rpm_dl_url"]["value"])') 

CTRL_PRV_IP=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["controller_private_ip"]["value"])') 
CTRL_PUB_IP=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["controller_public_ip"]["value"])') 

echo CTRL_PRV_IP=$CTRL_PRV_IP
echo CTRL_PUB_IP=$CTRL_PUB_IP

GATW_PRV_IP=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["gateway_private_ip"]["value"])') 
GATW_PUB_IP=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (obj["gateway_public_ip"]["value"])') 

echo GATW_PRV_IP=$GATW_PRV_IP
echo GATW_PUB_IP=$GATW_PUB_IP

WRKR_PRV_IPS=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (*obj["workers_private_ip"]["value"][0], sep=" ")') 
WRKR_PUB_IPS=$(cat output.json | python3 -c 'import json,sys;obj=json.load(sys.stdin);print (*obj["workers_public_ip"]["value"][0], sep=" ")') 

read -r -a WRKR_PRV_IPS <<< "$WRKR_PRV_IPS"
read -r -a WRKR_PUB_IPS <<< "$WRKR_PUB_IPS"

echo WRKR_PRV_IPS=${WRKR_PRV_IPS[@]}
echo WRKR_PUB_IPS=${WRKR_PUB_IPS[@]}

###############################################################################
# Test SSH connectivity to EC2 instances from local machine
###############################################################################

ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${CTRL_PUB_IP} 'echo CONTROLLER: $(hostname)'
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${GATW_PUB_IP} 'echo GATEWAY: $(hostname)'

for WRKR in ${WRKR_PUB_IPS[@]}; do 
   ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${WRKR} 'echo WORKER: $(hostname)'
done

###############################################################################
# Setup SSH keys for passwordless SSH
###############################################################################

# if ssh key doesn't exist on controller EC instance then create one
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${CTRL_PUB_IP} << ENDSSH
if [ -f ~/.ssh/id_rsa ]
then
   echo CONTROLLER: Found existing ~/.ssh/id.rsa so moving on...
else
   ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
   echo CONTROLLER: Created ~/.ssh/id.rsa
fi
ENDSSH

# We have password SSH access from our local machines to EC2, so we can utiise this to copy the Controller SSH key to the Gateway
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${CTRL_PUB_IP} "cat /home/centos/.ssh/id_rsa.pub" | \
  ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${GATW_PUB_IP} "cat >> /home/centos/.ssh/authorized_keys" 

# test passwordless SSH connection from Controller to Gateway
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${CTRL_PUB_IP} << ENDSSH
echo CONTROLLER: Connecting to GATEWAY ${GATW_PUB_IP}...
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa -T centos@${GATW_PRV_IP} "echo Connected!"
ENDSSH

# test passwordless SSH connection from Controller to Workers
for WRKR in ${WRKR_PRV_IPS[@]}; do 
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${CTRL_PUB_IP} << ENDSSH
echo CONTROLLER: Connecting to WORKER ${WRKR}...
ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa -T centos@${WRKR} "echo Connected!"
ENDSSH
done

###############################################################################
# Install RPMS
###############################################################################

# Gateway
ssh -o StrictHostKeyChecking=no -i ${LOCAL_SSH_PRV_KEY_PATH} -T centos@${GATW_PUB_IP} << ENDSSH
   curl -s -f ${EPIC_RPM_DL_URL} | grep proxy | awk '{print \$3}' | sed -r "s/([a-zA-Z0-9_+]*)(-[a-zA-Z0-9]+)?(-\S+)(-.*)/\1\2\3/" | xargs sudo yum install -y 
   sudo reboot
ENDSSH

echo 'Waiting for Gateway to restart '
while ! nc -w5 -z ${GATW_PUB_IP} 22; do echo -n '.'; done

 