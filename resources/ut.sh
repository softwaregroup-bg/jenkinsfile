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
    PREFETCH=$'COPY prefetch.json package.json\nRUN npm --production=false install'
fi
docker build -t ${JOB_NAME}:test . -f-<<EOF
FROM $BUILD_IMAGE
RUN set -xe \
    && apk add --no-cache bash git openssh \
    && git --version && bash --version && ssh -V && npm -v && node -v && yarn -v
WORKDIR /app
COPY .npmrc .npmrc
${PREFETCH}
COPY package.json package.json
RUN npm --production=false install
COPY . .
EOF
docker run -i --rm -v "$(pwd)/.lint:/app/.lint" ${JOB_NAME}:test /bin/sh -c "rm .lint/*;npm ls > .lint/npm-ls.txt" || true
docker run -i --rm \
    -v ~/.ssh:/root/.ssh:ro \
    -v ~/.npmrc:/root/.npmrc:ro \
    -v ~/.gitconfig:/root/.gitconfig:ro \
    -v "$(pwd)/.lint:/app/.lint" \
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
    ${JOB_NAME}:test npm run jenkins
docker run -i --rm -v $(pwd):/app newtmitch/sonar-scanner:3.2.0-alpine sonar-scanner \
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
  -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info
if [ "${GIT_BRANCH}" = "origin/master" ]; then
    docker build -t ${JOB_NAME}:prod . -f-<<EOF
FROM $JOB_NAME:test
RUN npm prune --production
EOF
    docker build -t ${JOB_NAME} . -f-<<EOF
FROM $IMAGE
COPY --from=${JOB_NAME}:prod /app /app
WORKDIR /app
CMD ["node", "index.js"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup.com:5001
    docker tag ${JOB_NAME} nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
    docker push nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
    docker rmi ${JOB_NAME}:prod ${JOB_NAME} nexus-dev.softwaregroup.com:5001/ut/${JOB_NAME}:latest
fi