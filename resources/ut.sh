#!/bin/bash
set -x
set -e
UT_MODULE=${gitlabSourceRepoName/impl-/}
TAP_TIMEOUT=1000
CONTAINER_NAME=$JOB_NAME-$BUILD_NUMBER
UT_PREFIX=ut_${UT_MODULE//[-\/\\]/_}_jenkins
if [ "$gitlabActionType" = "PUSH" ]; then
    git checkout -B ${GIT_BRANCH#origin/} --track remotes/${GIT_BRANCH}
fi
if [ -f "prefetch.json" ]; then
    PREFETCH=$'COPY --chown=node:node prefetch.json package.json\nRUN npm --production=false install'
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

if [[ ! $BUILD_IMAGE =~ ^ut-docker.*$ ]]; then
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
    -e UT_MODULE=$UT_MODULE \
    -e GIT_URL=$GIT_URL \
    -e GIT_BRANCH=$GIT_BRANCH \
    -e BRANCH_NAME=$BRANCH_NAME \
    -e BUILD_CAUSE=$BUILD_CAUSE \
    -e ${UT_PREFIX}_db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_db__connection__encryptionPass="$encryptionPass" \
    -e ${UT_PREFIX}_db__connection__database=${UT_MODULE}-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utAudit__db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_utAudit__db__connection__database=${UT_MODULE}-audit-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__connection__database=${UT_MODULE}-history-$JOB_NAME-${BUILD_NUMBER} \
    -e ${UT_PREFIX}_utHistory__db__create__password=$UT_DB_PASS \
    -e TAP_TIMEOUT=$TAP_TIMEOUT \
    --entrypoint=/bin/bash \
    ${JOB_NAME}:test -c "(git checkout -- .dockerignore || true) && npm run jenkins"
docker run --entrypoint=/bin/sh -i --rm -v $(pwd):/app newtmitch/sonar-scanner:3.2.0-alpine \
  -c "sonar-scanner \
  -Dsonar.host.url=https://sonar.softwaregroup.com/ \
  -Dsonar.projectKey=${UT_MODULE} \
  -Dsonar.projectName=${UT_MODULE} \
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
if [ "${GIT_BRANCH}" = "origin/master" ]; then
    docker build -t ${JOB_NAME}:prod . -f-<<EOF
        FROM $JOB_NAME:test
        RUN npm prune --production
EOF
    docker build -t ${JOB_NAME} . -f-<<EOF
        FROM $IMAGE
        RUN apk add --no-cache tzdata
        COPY --from=${JOB_NAME}:prod /app /app
        WORKDIR /app
        COPY dist dist
        ENTRYPOINT ["node", "index.js"]
        CMD ["server"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup.com:5001
    docker tag ${JOB_NAME} nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
    docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
    if [ "${ARMIMAGE}" ]; then
        docker build -t ${JOB_NAME}-arm . -f-<<EOF
            FROM $ARMIMAGE
            COPY --from=${JOB_NAME}:prod /app /app
            WORKDIR /app
            ENTRYPOINT ["node", "index.js"]
            CMD ["server"]
EOF
        docker tag ${JOB_NAME}-arm nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm:latest
        docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm:latest
        docker rmi ${JOB_NAME}:prod ${JOB_NAME} ${JOB_NAME}-arm nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}-arm:latest
    else
        docker rmi ${JOB_NAME}:prod ${JOB_NAME} nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
    fi
fi
