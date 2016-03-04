#!/bin/bash

# Before the script can be executed, the following must be done:

# * Create IAM user. TODO(mp) write about policies and friends.

# TODO(mp) when listing instances, take $SUFFIX into consideration!

set -e
#set -x

: ${ZONE:="us-east-1a"}

: ${SRC_IMAGE_ID:="ami-fce3c696"} # Ubuntu 14.04 LTS (HVM) at us-east-1
: ${IMAGE_NAME:="weavenet_ci"}

: ${INSTANCE_TYPE:="t2.micro"}
: ${INSTANCE_TAG:="weavenet_ci"}
: ${SEC_GROUP_NAME:="weavenet-ci"}

: ${KEY_NAME:="weavenet_ci"}
: ${SSH_KEY_FILE:="$HOME/.ssh/$KEY_NAME"}

: ${NUM_HOSTS:=5}
: ${AWSCLI:="aws"}
: ${SSHCMD:="ssh -o StrictHostKeyChecking=no -o CheckHostIp=no
             -o UserKnownHostsFile=/dev/null -l ubuntu -i $SSH_KEY_FILE"}

SUFFIX=""
if [ -n "$CIRCLECI" ]; then
	SUFFIX="-${CIRCLE_BUILD_NUM}-$CIRCLE_NODE_INDEX"
fi

# Creates and runs a set of VMs.
# Each VM is named after "host${ID}${SUFFIX}" and is tagged with $INSTANCE_TAG.
function setup {
    # Destroy previous machines (if any)
    destroy

    # Start instances
    image_id=$(ami_id)
    json=$(mktemp json.XXXXXXXXXX)
    run_instances $NUM_HOSTS $image_id > $json

    # Assign a name to each instance and
    # disable src/dst checks (required by awsvpc)
    i=1
    for vm in `jq -r -e ".Instances[].InstanceId" $json`; do
        $AWSCLI ec2 create-tags                             \
            --resources "$vm"                               \
            --tags "Key=Name,Value=\"$(vm_name $i)\""       \
                   "Key=$INSTANCE_TAG,Value=\"true\""
        $AWSCLI ec2 modify-instance-attribute               \
            --instance-id "$vm"                             \
            --no-source-dest-check
        ((i++))
    done

    # Populate /etc/hosts of local host and of each instance
	hosts=$(mktemp hosts.XXXXXXXXXX)
    # wait_for_hosts will populate $json as well
    wait_for_hosts $json
    names=$(vm_names)
    for vm in $names; do
		echo "$(internal_ip $json $vm) $vm" >> $hosts
    done
    for vm in $names; do
		sudo sed -i "/$vm/d" /etc/hosts
		sudo sh -c "echo \"$(external_ip $json $vm) $vm\" >>/etc/hosts"
		try_connect $vm
		copy_hosts $vm $hosts &
    done

	wait

    rm $json $hosts
}

# Creates AMI.
function make_template {
    # Check if image exists
    [[ $(ami_id) == "null" ]] || exit 0

    # Create an instance
    json=$(mktemp json.XXXXXXXXXX)
    run_instances 1 "$SRC_IMAGE_ID" > $json

    # Install docker and friends
    instance_id=$(jq -r -e ".Instances[0].InstanceId" $json)
    trap '$AWSCLI ec2 terminate-instances --instance-ids $instance_id > /dev/null' EXIT
    list_instances_by_id "$instance_id" > $json
    f=".Reservations[].Instances[].NetworkInterfaces[0].Association.PublicIp"
    public_ip=$(jq -r -e "$f" $json)
	try_connect "$public_ip"
    install_docker_on "$public_ip"

    # Create an image
    echo "Creating $IMAGE_NAME image from $instance_id instance"
    $AWSCLI ec2 create-image            \
        --instance-id "$instance_id"    \
        --name "$IMAGE_NAME"
    image_id=$(ami_id)
    wait_for_ami $image_id

    # Delete artifacts
    rm $json
}

# Destroy VMs and remove keys.
function destroy {
    delete_key_pair
    json=$(mktemp json.XXXXXXXXXX)
    list_instances >> $json
    instances=""
    for i in `jq -r -e ".Reservations[].Instances[].InstanceId" $json`; do
        instances="$i $instances"
    done

    echo "Terminating $instances instances"
    [[ ! -z "$instances" ]] &&
        $AWSCLI ec2 terminate-instances --instance-ids $instances > /dev/null

    rm $json
}

# Helpers

function run_instances {
    count="$1"
    image_id="$2"

    # Create keypair
    create_key_pair

    # Check whether a necessary security group exists
    ensure_sec_group

    echo "Creating $count instances of $image_id image"
    $AWSCLI ec2 run-instances                   \
        --image-id "$image_id"                  \
        --key-name "$KEY_NAME"                  \
        --placement "AvailabilityZone=$ZONE"    \
        --instance-type "$INSTANCE_TYPE"        \
        --security-groups "$SEC_GROUP_NAME"     \
        --count $count
}

function list_instances {
    $AWSCLI ec2 describe-instances                                      \
        --filters "Name=instance-state-name,Values=pending,running"     \
                  "Name=tag:$INSTANCE_TAG,Values=true"
}

function list_instances_by_id {
    ids="$1"
    $AWSCLI ec2 describe-instances --instance-ids $1
}

function ami_id {
    $AWSCLI ec2 describe-images --filter "Name=name,Values=$IMAGE_NAME" |
        jq -r ".Images[0].ImageId"
}

function ami_state {
    image_id="$1"
    $AWSCLI ec2 describe-images --image-ids "$image_id" |
        jq -r -e ".Images[0].State"
}

# Function blocks until image becomes ready (i.e. state != pending).
function wait_for_ami {
    image_id="$1"

    echo "Waiting for $image_id image"
    for i in {0..20}; do
        state=$(ami_state "$image_id")
        [[ "$state" != "pending" ]] && return
		sleep 60
	done
    echo "Done waiting"
}

function wait_for_hosts {
    json="$1"

    echo "Waiting for hosts"
    for vm in $(vm_names); do
        echo "Waiting for $vm"
        # TODO(mp) maybe parallelize
        wait_for_external_ip $json "$vm"
    done
    echo "Done waiting"
}

function wait_for_external_ip {
    json="$1"
    vm="$2"
    for i in {0..10}; do
        list_instances > $json
        ip=$(external_ip $json $vm)
        [[ ! -z "$ip" ]] && return
        sleep 2
    done
}

function vm_names {
	local names=
	for i in $(seq 1 $NUM_HOSTS); do
        names="$(vm_name $i) $names"
	done
	echo "$names"
}

function vm_name {
    id="$1"
    echo "host$id$SUFFIX"
}

function internal_ip {
    jq -r ".Reservations[].Instances[]
              | select (.Tags[].Value == \"$2\")
              | .NetworkInterfaces[0].PrivateIpAddress" $1
}

function external_ip {
    jq -r ".Reservations[].Instances[]
              | select (.Tags[].Value == \"$2\")
              | .NetworkInterfaces[0].Association.PublicIp" $1
}

function create_key_pair {
    function _create {
        $AWSCLI ec2 create-key-pair --key-name $KEY_NAME 2>&1
    }

    if ! RET=$(_create); then
        if echo "$RET" | grep -q "InvalidKeyPair\.Duplicate"; then
            delete_key_pair
            RET=$(_create)
        else
            echo "$RET"
            exit -1
        fi
    fi

    echo "Created $KEY_FILE keypair"
    echo "Writing $KEY_FILE into $SSH_KEY_FILE"

    echo "$RET" | jq -r .KeyMaterial > $SSH_KEY_FILE
    chmod 400 $SSH_KEY_FILE
}

function delete_key_pair {
    echo "Deleting $KEY_NAME keypair"
    $AWSCLI ec2 delete-key-pair --key-name $KEY_NAME
    rm -f "$SSH_KEY_FILE" || true
}

function ensure_sec_group {
    $AWSCLI ec2 describe-security-groups |                              \
        jq -r -e ".SecurityGroups[] |
                select (.GroupName == \"$SEC_GROUP_NAME\")" > /dev/null \
        || create_sec_group
}

function create_sec_group {
    echo "Creating $SEC_GROUP_NAME security group"
    $AWSCLI ec2 create-security-group               \
        --group-name "$SEC_GROUP_NAME"              \
        --description "Weave CircleCI" > /dev/null
    $AWSCLI ec2 authorize-security-group-ingress    \
        --group-name "$SEC_GROUP_NAME"              \
        --source-group "$SEC_GROUP_NAME"            \
        --protocol all
    $AWSCLI ec2 authorize-security-group-ingress    \
        --group-name "$SEC_GROUP_NAME"              \
        --protocol tcp --port 22                    \
        --cidr "0.0.0.0/0"
    $AWSCLI ec2 authorize-security-group-ingress    \
        --group-name "$SEC_GROUP_NAME"              \
        --protocol tcp --port 2375                  \
        --cidr "0.0.0.0/0"
}

# Commons (taken from gce.sh, and slightly modified)

# TODO(mp) DRY

function hosts {
	hosts=
	json=$(mktemp json.XXXXXXXXXX)
	list_instances > $json
	for name in $(vm_names); do
		hostname="$name"
		hosts="$hostname $hosts"
	done
	echo export SSH=\"$SSHCMD\"
	echo export HOSTS=\"$hosts\"
	rm $json
}

function try_connect {
    echo "Trying to connect to $1"
	for i in {0..10}; do
		$SSHCMD -t $1 true && return
		sleep 2
	done
    echo "Connected to $1"
}

function copy_hosts {
	hostname=$1
	hosts=$2

	cat $hosts | $SSHCMD -t "$hostname" "sudo -- sh -c \"cat >>/etc/hosts\""
}

function install_docker_on {
    # TODO(mp) bring back `-s overlay` opt to DOCKER_OPTS.
    # TODO(mp) *maybe* use `vagrant` user instead of default `ubuntu`.

	name=$1
	$SSHCMD -t $name sudo bash -x -s <<EOF
curl -sSL https://get.docker.com/gpg | sudo apt-key add -
curl -sSL https://get.docker.com/ | sh
apt-get update -qq;
apt-get install -q -y --force-yes --no-install-recommends ethtool;
usermod -a -G docker ubuntu;
echo 'DOCKER_OPTS="-H unix:///var/run/docker.sock -H unix:///var/run/alt-docker.sock -H tcp://0.0.0.0:2375"' >> /etc/default/docker;
service docker restart
EOF
	# It seems we need a short delay for docker to start up, so I put this in
	# a separate ssh connection.  This installs nsenter.
	$SSHCMD -t $name sudo docker run --rm -v /usr/local/bin:/target jpetazzo/nsenter
}

# Main

case "$1" in
setup)
	setup
	;;
hosts)
	hosts
	;;
destroy)
	destroy
	;;
make_template)
    make_template
    ;;
esac
