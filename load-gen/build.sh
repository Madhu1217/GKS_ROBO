#!/bin/sh

# get the tag info
eval $(egrep '[A-Z]+=' ../.env)

echo "Repo $REPO"
echo "Tag $TAG"

docker build -t ${REPO}/load:${TAG} . && docker tag ${REPO}/load:${TAG} ${REPO}/load

if [ "$1" = "push" ]
then
    echo "pushing..."
    docker push ${REPO}/load:${TAG}
    docker push ${REPO}/load
fi
