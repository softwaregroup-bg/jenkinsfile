#!/bin/bash
set -x
set -e
UT_PROJECT=`git config --get remote.origin.url | sed -n -r 's/.*\/(ut-.*|impl-.*|.*-ut).git/\1/p'`
RELEASE=
PREFETCH=
NPMRC=
RUNAPK=
UT_IMPL=
UT_MODULE=
LERNA=
if [[ ${UT_PROJECT} =~ impl-(.*) ]]; then
    UT_IMPL=${BASH_REMATCH[1]}
    UT_MODULE=${UT_IMPL}
    UT_PREFIX=ut_${UT_IMPL//[-\/\\]/_}_jenkins
fi
if [[ ${UT_PROJECT} =~ ut-(.*) ]]; then
    UT_MODULE=${BASH_REMATCH[1]}
    UT_PREFIX=ut_${BASH_REMATCH[1]//[-\/\\]/_}_jenkins
fi
[[ ${GIT_BRANCH} =~ master|(major|minor|patch|hotfix)/[^\/]*$ ]] || true && RELEASE=${BASH_REMATCH[0]}
# add origin/ if missing
GIT_BRANCH=origin/${GIT_BRANCH#origin/}
BRANCH_NAME=${GIT_BRANCH}
# replace / \ %2f %2F with -
TAP_TIMEOUT=1000
if [[ $RELEASE && "${CHANGE_ID}" = "" ]]; then
    git checkout -B ${GIT_BRANCH#origin/} --track remotes/${GIT_BRANCH}
fi
if [ -f "prefetch.json" ]; then
    PREFETCH=$'COPY --chown=node:node prefetch.json package.json\nRUN npm --production=false install'
fi
if [ -f "prefetch" ]; then
    PREFETCH=$(<prefetch)
fi
if [ -f ".npmrc" ]; then
    NPMRC='COPY --chown=node:node .npmrc .npmrc'
fi
if [ -f "lerna.json" ]; then
    LERNA=$'COPY --chown=node:node lerna.json lerna.json\nCOPY --chown=node:node packages packages/'
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

if [[ ! $BUILD_IMAGE =~ ^softwaregroup/(impl|ut)-docker.*$ ]]; then
    RUNAPK=$(cat <<END
RUN set -xe\
 && apk add --no-cache bash git openssh python make g++\
 && git --version && bash --version && ssh -V && npm -v && node -v && yarn -v\
 && mkdir /var/lib/SoftwareGroup && chown -R node:node /var/lib/SoftwareGroup
WORKDIR /app
RUN chown -R node:node /app
USER node
END
)
fi

docker build -t ${UT_PROJECT}:test . -f-<<EOF
FROM $BUILD_IMAGE
$RUNAPK
${NPMRC}
${LERNA}
${PREFETCH}
COPY --chown=node:node package.json package.json
RUN npm --production=false install
COPY --chown=node:node . .
EOF
docker run -u node:node -i --rm -v "$(pwd)/.lint:/app/.lint" ${UT_PROJECT}:test /bin/sh -c "npm ls > .lint/npm-ls.txt" || true
docker run -u node:node -i --rm \
    -v ~/.ssh:/home/node/.ssh:ro \
    -v ~/.npmrc:/home/node/.npmrc:ro \
    -v ~/.gitconfig:/home/node/.gitconfig:ro \
    -v "$(pwd)/.git:/app/.git" \
    -v "$(pwd)/.lint:/app/.lint" \
    -v "$(pwd)/dist:/app/dist" \
    -v "$(pwd)/coverage:/app/coverage" \
    -e JOB_TYPE=$JOB_TYPE \
    -e JOB_NAME=${UT_PROJECT} \
    -e BUILD_ID=$BUILD_ID \
    -e BUILD_NUMBER=$BUILD_NUMBER \
    -e UT_ENV=jenkins \
    -e UT_DB_PASS=$UT_DB_PASS \
    -e UT_MASTER_KEY=$UT_MASTER_KEY \
    -e UT_MODULE=$UT_MODULE \
    -e GIT_URL=$GIT_URL \
    -e GIT_BRANCH=$GIT_BRANCH \
    -e BRANCH_NAME=$BRANCH_NAME \
    -e BUILD_CAUSE=$BUILD_CAUSE \
    -e ${UT_PREFIX}_db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_db__connection__encryptionPass="$encryptionPass" \
    -e ${UT_PREFIX}_db__connection__database=${UT_MODULE}-${UT_PROJECT}-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utAudit__db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_utAudit__db__connection__database=${UT_MODULE}-audit-${UT_PROJECT}-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__connection__database=${UT_MODULE}-history-${UT_PROJECT}-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__create__password=$UT_DB_PASS \
    -e TAP_TIMEOUT=$TAP_TIMEOUT \
    --entrypoint=/bin/bash \
    ${UT_PROJECT}:test -c "(git checkout -- .dockerignore || true) && npm run jenkins"
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
  -Dsonar.branch=${GIT_BRANCH} \
  -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info \
  && chown -R $(id -u):$(id -g) /app/.scannerwork"
if [[ $RELEASE && ${UT_IMPL} ]]; then
    TAG=${RELEASE//[\/\\]/-}
    if [ "$TAG" = "master" ]; then TAG="latest"; fi
    docker build -t ${UT_PROJECT}:$TAG . -f-<<EOF
        FROM ${UT_PROJECT}:test
        RUN npm prune --production
EOF
    docker build -t ${UT_PROJECT}-amd64 . -f-<<EOF
        FROM $IMAGE
        RUN apk add --no-cache tzdata
        COPY --from=${UT_PROJECT}:$TAG /app /app
        WORKDIR /app
        COPY dist dist
        ENTRYPOINT ["node", "index.js"]
        CMD ["server"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup.com:5001
    if [ "${ARMIMAGE}" ]; then
        docker build -t ${UT_PROJECT}-arm64 . -f-<<EOF
            FROM $ARMIMAGE
            COPY --from=${UT_PROJECT}:$TAG /app /app
            WORKDIR /app
            ENTRYPOINT ["node", "index.js"]
            CMD ["server"]
EOF
        docker tag ${UT_PROJECT}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG
        docker tag ${UT_PROJECT}-arm64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        docker rmi ${UT_PROJECT}:$TAG ${UT_PROJECT}-amd64 ${UT_PROJECT}-arm64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest annotate nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG --os linux --arch arm64 --variant v8
        # DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
    else
        docker tag ${UT_PROJECT}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
        docker rmi ${UT_PROJECT}:$TAG ${UT_PROJECT}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
    fi
fi
