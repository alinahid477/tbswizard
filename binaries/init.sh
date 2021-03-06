#!/bin/bash

export $(cat /root/.env | xargs)
unset doinstall

printf "\n\nsetting executable permssion to all binaries sh\n\n"
ls -l /root/binaries/*.sh | awk '{print $9}' | xargs chmod +x

printf "\n\nChecking dependencies...\n\n"
isexist=$(ls ~/binaries | grep '^kp$')
if [[ -z $isexist ]]
then
    printf "\nError: required binary kp not found in ~/binaries dir."
    exit
fi


isexists=$(ls -l /root/.ssh/id_rsa)
if [[ -n $isexists && -n $BASTION_HOST ]]
then
    chmod 600 /root/.ssh/id_rsa 
    isrsacommented=$(cat ~/Dockerfile | grep '#\s*COPY .ssh/id_rsa /root/.ssh/')
    if [[ -n $isrsacommented ]]
    then
        printf "\n\nBoth id_rsa file and bastion host input found...\n"
        printf "Adjusting the dockerfile to include id_rsa...\n"
        
        sed -i '/COPY .ssh\/id_rsa \/root\/.ssh\//s/^# //' ~/Dockerfile
        sed -i '/RUN chmod 600 \/root\/.ssh\/id_rsa/s/^# //' ~/Dockerfile

        printf "\n\nDockerfile is now adjusted with id_rsa.\n\n"
        printf "\n\nPlease rebuild the docker image and run again (or ./start.sh tbs forcebuild).\n\n"
        exit 1
    fi
fi


printf "\n\n\n***********Checking kubeconfig...*************\n"


if [[ -n $TKG_VSPHERE_SUPERVISOR_ENDPOINT ]]
then

    IS_KUBECTL_VSPHERE_EXISTS=$(kubectl vsphere)
    if [ -z "$IS_KUBECTL_VSPHERE_EXISTS" ]
    then 
        printf "\n\nkubectl vsphere not installed.\nChecking for binaries...\n"
        IS_KUBECTL_VSPHERE_BINARY_EXISTS=$(ls ~/binaries/ | grep kubectl-vsphere)
        if [ -z "$IS_KUBECTL_VSPHERE_BINARY_EXISTS" ]
        then            
            printf "\n\nDid not find kubectl-vsphere binary in ~/binaries/.\nDownloding in ~/binaries/ directory...\n"
            if [[ -n $BASTION_HOST ]]
            then
                ssh -i /root/.ssh/id_rsa -4 -fNT -L 443:$TKG_VSPHERE_SUPERVISOR_ENDPOINT:443 $BASTION_USERNAME@$BASTION_HOST
                curl -kL https://localhost/wcp/plugin/linux-amd64/vsphere-plugin.zip -o ~/binaries/vsphere-plugin.zip
                sleep 2
                fuser -k 443/tcp
            else 
                curl -kL https://$TKG_VSPHERE_SUPERVISOR_ENDPOINT/wcp/plugin/linux-amd64/vsphere-plugin.zip -o ~/binaries/vsphere-plugin.zip
            fi            
            unzip ~/binaries/vsphere-plugin.zip -d ~/binaries/vsphere-plugin/
            mv ~/binaries/vsphere-plugin/bin/kubectl-vsphere ~/binaries/
            rm -R ~/binaries/vsphere-plugin/
            rm ~/binaries/vsphere-plugin.zip
            
            printf "\n\nkubectl-vsphere is now downloaded in ~/binaries/...\n"
        else
            printf "kubectl-vsphere found in binaries dir...\n"
        fi
        printf "\n\nAdjusting the dockerfile to incluse kubectl-binaries...\n"
        sed -i '/COPY binaries\/kubectl-vsphere \/usr\/local\/bin\//s/^# //' ~/Dockerfile
        sed -i '/RUN chmod +x \/usr\/local\/bin\/kubectl-vsphere/s/^# //' ~/Dockerfile

        printf "\n\nDockerfile is now adjusted with kubectl-vsphre.\n\n"
        printf "\n\nPlease rebuild the docker image and run again (or ./start.sh tbs forcebuild).\n\n"
        exit 1
    else
        printf "\nfound kubectl-vsphere...\n"
    fi

    printf "\n\n\n**********vSphere Cluster login...*************\n"
    
    export KUBECTL_VSPHERE_PASSWORD=$(echo $TKG_VSPHERE_PASSWORD | xargs)


    EXISTING_JWT_EXP=$(awk '/users/{flag=1} flag && /'$TKG_VSPHERE_CLUSTER_ENDPOINT'/{flag2=1} flag2 && /token:/ {print $NF;exit}' /root/.kube/config | jq -R 'split(".") | .[1] | @base64d | fromjson | .exp')

    if [ -z "$EXISTING_JWT_EXP" ]
    then
        EXISTING_JWT_EXP=$(date  --date="yesterday" +%s)
        # printf "\n SET EXP DATE $EXISTING_JWT_EXP"
    fi
    CURRENT_DATE=$(date +%s)

    if [ "$CURRENT_DATE" -gt "$EXISTING_JWT_EXP" ]
    then
        printf "\n\n\n***********Login into cluster...*************\n"
        rm /root/.kube/config
        rm -R /root/.kube/cache
        if [[ -z $BASTION_HOST ]]
        then
            kubectl vsphere login --tanzu-kubernetes-cluster-name $TKG_VSPHERE_CLUSTER_NAME --server $TKG_VSPHERE_SUPERVISOR_ENDPOINT --insecure-skip-tls-verify -u $TKG_VSPHERE_USERNAME
            kubectl config use-context $TKG_VSPHERE_CLUSTER_NAME
        else
            printf "\n\n\n***********Creating Tunnel through bastion $BASTION_USERNAME@$BASTION_HOST ...*************\n"            
            ssh-keyscan $BASTION_HOST > /root/.ssh/known_hosts
            printf "\nssh -i /root/.ssh/id_rsa -4 -fNT -L 443:$TKG_VSPHERE_SUPERVISOR_ENDPOINT:443 $BASTION_USERNAME@$BASTION_HOST\n"
            ssh -i /root/.ssh/id_rsa -4 -fNT -L 443:$TKG_VSPHERE_SUPERVISOR_ENDPOINT:443 $BASTION_USERNAME@$BASTION_HOST
                        
            printf "\n\n\n***********Authenticating to cluster $TKG_VSPHERE_CLUSTER_NAME-->IP:$TKG_VSPHERE_CLUSTER_ENDPOINT  ...*************\n"
            kubectl vsphere login --tanzu-kubernetes-cluster-name $TKG_VSPHERE_CLUSTER_NAME --server kubernetes --insecure-skip-tls-verify -u $TKG_VSPHERE_USERNAME
            
            printf "\n\n\n***********Adjusting your kubeconfig...*************\n"
            sed -i 's/kubernetes/'$TKG_VSPHERE_SUPERVISOR_ENDPOINT'/g' ~/.kube/config
            kubectl config use-context $TKG_VSPHERE_CLUSTER_NAME

            sed -i '0,/'$TKG_VSPHERE_CLUSTER_ENDPOINT'/s//kubernetes/' ~/.kube/config
            ssh -i /root/.ssh/id_rsa -4 -fNT -L 6443:$TKG_VSPHERE_CLUSTER_ENDPOINT:6443 $BASTION_USERNAME@$BASTION_HOST
        fi
    else
        printf "\n\n\nCuurent kubeconfig has not expired. Using the existing one found at .kube/config\n"
        if [[ -n $BASTION_HOST ]]
        then
            printf "\n\n\n***********Creating K8s endpoint Tunnel through bastion $BASTION_USERNAME@$BASTION_HOST ...*************\n"
            ssh -i /root/.ssh/id_rsa -4 -fNT -L 6443:$TKG_VSPHERE_CLUSTER_ENDPOINT:6443 $BASTION_USERNAME@$BASTION_HOST
        fi
    fi
else
    printf "\n\n\n**********login based on kubeconfig...*************\n"
    if [[ -n $BASTION_HOST ]]
    then
        printf "Bastion host specified...\n"
        printf "Extracting server url...\n"
        serverurl=$(awk '/server/ {print $NF;exit}' /root/.kube/config | awk -F/ '{print $3}' | awk -F: '{print $1}')
        printf "server url: $serverurl\n"
        printf "Extracting port...\n"
        port=$(awk '/server/ {print $NF;exit}' /root/.kube/config | awk -F/ '{print $3}' | awk -F: '{print $2}')
        if [[ -z $port ]]
        then
            port=80
        fi
        printf "port: $port\n"
        printf "\n\n\n***********Creating K8s endpoint Tunnel through bastion $BASTION_USERNAME@$BASTION_HOST ...*************\n"
        ssh -i /root/.ssh/id_rsa -4 -fNT -L $port:$serverurl:$port $BASTION_USERNAME@$BASTION_HOST
    fi
fi


if [[ -n $TMC_API_TOKEN ]]
then
    printf "\nChecking TMC cli...\n"
    ISTMCEXISTS=$(tmc --help)
    sleep 1
    if [ -z "$ISTMCEXISTS" ]
    then
        printf "\n\ntmc command does not exist.\n\n"
        printf "\n\nChecking for binary presence...\n\n"
        IS_TMC_BINARY_EXISTS=$(ls ~/binaries/ | grep tmc)
        sleep 2
        if [ -z "$IS_TMC_BINARY_EXISTS" ]
        then
            printf "\n\nBinary does not exist in ~/binaries directory.\n"
            printf "\nIf you could like to attach the newly created TKG clusters to TMC then please download tmc binary from https://{orgname}.tmc.cloud.vmware.com/clidownload and place in the ~/binaries directory.\n"
            printf "\nAfter you have placed the binary file you can, additionally, uncomment the tmc relevant in the Dockerfile.\n\n"
        else
            printf "\n\nTMC binary found...\n"
            printf "\n\nAdjusting Dockerfile\n"
            sed -i '/COPY binaries\/tmc \/usr\/local\/bin\//s/^# //' ~/Dockerfile
            sed -i '/RUN chmod +x \/usr\/local\/bin\/tmc/s/^# //' ~/Dockerfile
            sleep 2
            printf "\nDONE..\n"
            printf "\n\nPlease build this docker container again and run.\n"
            exit 1
        fi
    else
        printf "\n\ntmc command found.\n\n"
    fi
fi


printf "\n\nChecking connected k8s cluster\n\n"
kubectl get ns
printf "\n"
while true; do
    read -p "Confirm if you are seeing expected namespaces to proceed further? [y/n]: " yn
    case $yn in
        [Yy]* ) printf "\nyou confirmed yes\n"; break;;
        [Nn]* ) printf "\n\nYou said no. \n\nExiting...\n\n"; exit 1;;
        * ) echo "Please answer y or n.";;
    esac
done


printf "\n\nChecking if TBS is already installed on k8s cluster"
isexist=$(kubectl get ns | grep -w build-service)
if [[ -z $isexist ]]
then
    printf "\n\nTanzu Build Service is not found in the k8s cluster.\n\n"
    if [[ -z $COMPLETE || $COMPLETE == 'NO' ]]
    then
        isexist="n"    
    fi
else
    printf "\n\nNamespace build-service found in the k8s cluster.\n\n"
    if [[ -z $COMPLETE || $COMPLETE == 'NO' ]]
    then
        printf "\n\n.env is not marked as complete. Marking as complete.\n\n"
        sed -i '/COMPLETE/d' /root/.env
        printf "\nCOMPLETE=YES" >> /root/.env
    fi
fi

if [[ $isexist == "n" ]]
then
    while true; do
        read -p "Confirm if you like to deploy Tanzu Build Service on this k8s cluster now [y/n]: " yn
        case $yn in
            [Yy]* ) doinstall="y"; printf "\nyou confirmed yes\n"; break;;
            [Nn]* ) printf "\n\nYou said no.\n"; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
fi

if [[ $doinstall == "y" ]] 
then
    source ~/binaries/tbsinstall.sh
    unset inp
    while true; do
        read -p "Confirm if TBS deployment/installation successfully completed and cluster builder list is displayed [y/n]: " yn
        case $yn in
            [Yy]* ) inp="y"; printf "\nyou confirmed yes\n"; break;;
            [Nn]* ) printf "\n\nYou said no.\n"; break;;
            * ) echo "Please answer y or n.";;
        esac
    done
    printf "\n\nGreat! Now that TBS is installed you can use tbsbuilderwizard to configuer TBS with your pipeline or code and container registry\n\n"
    unset inp2
    if [[ $inp == "y" ]]
    then
        while true; do
            read -p "Confirm if you would like to configure a default builder now [y/n]: " yn
            case $yn in
                [Yy]* ) inp2="y"; printf "\nyou confirmed yes\n"; break;;
                [Nn]* ) printf "\n\nYou said no.\n"; break;;
                * ) echo "Please answer y or n.";;
            esac
        done   
    fi
    if [[ $inp2 == "y" ]]
    then
        printf "\n\nLaunching TBS Builder Wizard to create default-builder in namespace: default...\n\n"
        source ~/binaries/tbsbuilderwizard.sh -n default-builder -k default --wizard
    fi
fi

printf "\nYour available wizards are:\n"
echo -e "\t~/binaries/tbsinstall.sh"
echo -e "\t~/binaries/tbsbuilderwizard.sh --help"

cd ~

/bin/bash