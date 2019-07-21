FROM cubeearth/halyard

USER root

RUN apt-get update && apt-get -y upgrade && apt-get install -y wget vim jq && \
	sh -c "$(curl -sL https://github.com/Cube-Earth/Scripts/raw/master/shell/k8s/pod/prepare.sh)" - -c certs -c run

#USER user

COPY scripts/ /usr/local/bin/

#VOLUME /home/user/.kube

#EXPOSE 8064

ENTRYPOINT [ "/usr/local/bin/run.sh" ]
