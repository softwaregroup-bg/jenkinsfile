#!/bin/bash
set -x
set -e
GIT_BRANCH=`git rev-parse --abbrev-ref HEAD`
UT_PROJECT=`git remote get-url origin | sed -n -r 's/.*\/(ut-.*|impl-.*).git/\1/p'`
[[ ${UT_PROJECT} =~ impl-(.*) ]]; UT_IMPL=${BASH_REMATCH[1]}
[[ ${UT_PROJECT} =~ ut-(.*) ]]; UT_MODULE=${BASH_REMATCH[1]}
[[ ${GIT_BRANCH} =~ master|(major|minor|patch|hotfix)/[^\/]*$ ]]; RELEASE=${BASH_REMATCH[0]}
TAP_TIMEOUT=1000
CONTAINER_NAME=$JOB_NAME-$BUILD_NUMBER
UT_PREFIX=ut_${UT_IMPL//[-\/\\]/_}_jenkins
if [[ $RELEASE && "${CHANGE_ID}" = "" ]]; then
    git checkout -B ${GIT_BRANCH} --track remotes/origin/${GIT_BRANCH}
fi
if [ -f "prefetch.json" ]; then
    PREFETCH=$'COPY --chown=node:node prefetch.json package.json\nRUN npm --production=false install'
fi
if [ -f "prefetch" ]; then
    PREFETCH=$(<prefetch)
fi

# Create prerequisite folders
for item in coverage .lint dist
do
    if [ -d $item ]
    then
        rm -rf $item
    fi
    mkdir $item
done

if [[ ! $BUILD_IMAGE =~ ^softwaregroup/ut-docker.*$ ]]; then
    RUNAPK=$(cat <<END
RUN set -xe\
 && apk add --no-cache bash git openssh python make g++\
 && git --version && bash --version && ssh -V && npm -v && node -v && yarn -v\
 && mkdir /var/lib/SoftwareGroup && chown -R node:node /var/lib/SoftwareGroup
WORKDIR /app
END
)
fi

docker build -t ${JOB_NAME}:test . -f-<<EOF
FROM $BUILD_IMAGE
$RUNAPK
COPY --chown=node:node .npmrc .npmrc
${PREFETCH}
COPY --chown=node:node package.json package.json
RUN npm --production=false install
COPY --chown=node:node . .
EOF
docker run -u node:node -i --rm -v "$(pwd)/.lint:/app/.lint" ${JOB_NAME}:test /bin/sh -c "npm ls > .lint/npm-ls.txt" || true
docker run -u node:node -i --rm \
    -v ~/.ssh:/home/node/.ssh:ro \
    -v ~/.npmrc:/home/node/.npmrc:ro \
    -v ~/.gitconfig:/home/node/.gitconfig:ro \
    -v "$(pwd)/.git:/app/.git" \
    -v "$(pwd)/.lint:/app/.lint" \
    -v "$(pwd)/dist:/app/dist" \
    -v "$(pwd)/coverage:/app/coverage" \
    -e JOB_TYPE=$JOB_TYPE \
    -e JOB_NAME=$JOB_NAME \
    -e BUILD_ID=$BUILD_ID \
    -e BUILD_NUMBER=$BUILD_NUMBER \
    -e UT_ENV=jenkins \
    -e UT_DB_PASS=$UT_DB_PASS \
    -e UT_MODULE=$UT_IMPL \
    -e GIT_URL=$GIT_URL \
    -e GIT_BRANCH=origin/$GIT_BRANCH \
    -e BRANCH_NAME=$BRANCH_NAME \
    -e BUILD_CAUSE=$BUILD_CAUSE \
    -e ${UT_PREFIX}_db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_db__connection__encryptionPass="$encryptionPass" \
    -e ${UT_PREFIX}_db__connection__database=${UT_IMPL}-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utAudit__db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_utAudit__db__connection__database=${UT_IMPL}-audit-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__connection__database=${UT_IMPL}-history-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__create__password=$UT_DB_PASS \
    -e TAP_TIMEOUT=$TAP_TIMEOUT \
    --entrypoint=/bin/bash \
    ${JOB_NAME}:test -c "(git checkout -- .dockerignore || true) && npm run jenkins"
docker run --entrypoint=/bin/sh -i --rm -v $(pwd):/app newtmitch/sonar-scanner:3.2.0-alpine \
  -c "sonar-scanner \
  -Dsonar.host.url=https://sonar.softwaregroup.com/ \
  -Dsonar.projectKey=${UT_PROJECT} \
  -Dsonar.projectName=${UT_PROJECT} \
  -Dsonar.projectVersion=1 \
  -Dsonar.projectBaseDir=/app \
  -Dsonar.sources=. \
  -Dsonar.inclusions=**/*.js \
  -Dsonar.exclusions=node_modules/**/*,coverage/**/*,test/**/*,tap-snapshots/**/* \
  -Dsonar.tests=. \
  -Dsonar.test.inclusions=test/**/*.js,**/*.test.js \
  -Dsonar.test.exclusions=node_modules/**/*,coverage/**/* \
  -Dsonar.language=js \
  -Dsonar.branch=origin/${GIT_BRANCH} \
  -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info \
  && chown -R $(id -u):$(id -g) /app/.scannerwork"
if [ $RELEASE && ${UT_IMPL} ]; then
    [[ $RELEASE =~ \/(.*)$ ]]; TAG=${BASH_REMATCH[1]}
    if [ "$TAG" = "" ]; then TAG="latest"; fi
    docker build -t ${JOB_NAME}:$RELEASE . -f-<<EOF
        FROM $JOB_NAME:test
        RUN npm prune --production
EOF
    docker build -t ${JOB_NAME}-amd64 . -f-<<EOF
        FROM $IMAGE
        RUN apk add --no-cache tzdata
        COPY --from=${JOB_NAME}:$RELEASE /app /app
        WORKDIR /app
        COPY dist dist
        ENTRYPOINT ["node", "index.js"]
        CMD ["server"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup.com:5001
    if [ "${ARMIMAGE}" ]; then
        docker build -t ${JOB_NAME}-arm64 . -f-<<EOF
            FROM $ARMIMAGE
            COPY --from=${JOB_NAME}:$RELEASE /app /app
            WORKDIR /app
            ENTRYPOINT ["node", "index.js"]
            CMD ["server"]
EOF
        docker tag ${JOB_NAME}-amd64 nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-amd64:$TAG
        docker tag ${JOB_NAME}-arm64 nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-amd64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm64:$TAG
        docker rmi ${JOB_NAME}:$RELEASE ${JOB_NAME}-amd64 ${JOB_NAME}-arm64 nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm64:$TAG
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME:$TAG nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME-arm64:$TAG
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest annotate nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME:$TAG nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME-arm64:$TAG --os linux --arch arm64 --variant v8
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push nexus-dev.softwaregroup.com:5001/ut/$JOB_NAME:$TAG
    else
        docker tag ${JOB_NAME}-amd64 nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:$TAG
        docker rmi ${JOB_NAME}:$RELEASE ${JOB_NAME}-amd64 nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:$TAG
    fi
fi
