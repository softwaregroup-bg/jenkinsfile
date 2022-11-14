#!/bin/bash
set -x
set -e
UT_PROJECT=`git config --get remote.origin.url | sed -n -r 's/.*\/(ut-.*|impl-.*|.*-ut).git/\1/p'`
RELEASE=
PREFETCH=
PREFETCH_PROD=
NPMRC=
RUNAPK=
UT_IMPL=
UT_MODULE=
SONAR_PREFIX=
LERNA=
DBSUFFIX=
if [[ ${CHANGE_ID} ]]; then
    DBSUFFIX=-${CHANGE_ID}
fi
if [[ ${UT_PROJECT} =~ impl-(.*) ]]; then
    # SONAR_PREFIX=ut5/
    UT_IMPL=${BASH_REMATCH[1]}
    UT_MODULE=${UT_IMPL}
    UT_PREFIX=ut_${UT_IMPL//[-\/\\]/_}_jenkins
    docker pull nexus-dev.softwaregroup.com:5000/softwaregroup/impl-gallium
fi
if [[ ${UT_PROJECT} =~ ut-(.*) ]]; then
    # SONAR_PREFIX=ut5impl/
    UT_MODULE=${BASH_REMATCH[1]}
    UT_PREFIX=ut_${BASH_REMATCH[1]//[-\/\\]/_}_jenkins
    docker pull nexus-dev.softwaregroup.com:5000/softwaregroup/node-gallium
    docker pull nexus-dev.softwaregroup.com:5000/softwaregroup/ut-gallium
fi
[[ ${GIT_BRANCH} =~ master|(major|minor|patch|hotfix)/[^\/]*$ ]] || true && RELEASE=${BASH_REMATCH[0]}
# add origin/ if missing
GIT_BRANCH=origin/${GIT_BRANCH#origin/}
BRANCH_NAME=${GIT_BRANCH}
# replace / \ %2f %2F with -
TAP_TIMEOUT=1000
TEST_IMAGE_TAG=test-${EXECUTOR_NUMBER}
if [[ $RELEASE && "${CHANGE_ID}" = "" ]]; then
    git checkout -B ${GIT_BRANCH#origin/} --track remotes/${GIT_BRANCH}
fi
if [ -f "prefetch.json" ]; then
    PREFETCH=$'COPY --chown=node:node prefetch.json package.json\nRUN npm --production=false install'
fi
if [ -f "prefetch" ]; then
    PREFETCH=$(<prefetch)
fi
if [ -f "prefetch_prod" ]; then
    PREFETCH_PROD=$(<prefetch_prod)
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

if [[ ! $BUILD_IMAGE =~ softwaregroup/(impl|ut|node)-(docker|gallium).*$ ]]; then
    RUNAPK=$(cat <<END
RUN set -xe\
 && apt install git openssh-client python3 make g++ tzdata \
 && git --version && bash --version && ssh -V && npm -v && node -v && yarn -v\
 && mkdir /var/lib/SoftwareGroup && chown -R node:node /var/lib/SoftwareGroup
WORKDIR /app
RUN chown -R node:node /app
USER node
END
)
fi

export DOCKER_BUILDKIT=1

docker build -t ${UT_PROJECT}:${TEST_IMAGE_TAG} . -f-<<EOF
# syntax=docker/dockerfile:experimental
FROM $BUILD_IMAGE
$RUNAPK
${NPMRC}
${LERNA}
${PREFETCH}
COPY --chown=node:node package.json package.json
# RUN --mount=type=cache,target=/home/node/.npm,mode=0777,uid=1000,gid=1000 \ # https://community.sonatype.com/t/cannot-install-with-registry-npm-group/6279
RUN mkdir -p /app/node_modules/.cache \
  && npm --legacy-peer-deps install \
  && npm config delete cache
COPY --chown=node:node . .
EOF
docker run -u node:node -i --rm -v "$(pwd)/.lint:/app/.lint" ${UT_PROJECT}:${TEST_IMAGE_TAG} /bin/sh -c "npm ls -a > .lint/npm-ls.txt" || true
docker run -u node:node -i \
    -v ~/.ssh:/home/node/.ssh:ro \
    -v ~/.npmrc:/home/node/.npmrc:ro \
    -v ~/.gitconfig:/home/node/.gitconfig:ro \
    -v "$(pwd)/.git:/app/.git" \
    -v "$(pwd)/.lint:/app/.lint" \
    -v "$(pwd)/dist:/app/dist" \
    -v "$(pwd)/coverage:/app/coverage" \
    -v "node_modules_cache:/app/node_modules/.cache" \
    -e TAP_JOBS=4 \
    -e JOB_TYPE=$JOB_TYPE \
    -e JOB_NAME=${UT_PROJECT} \
    -e BUILD_ID=$BUILD_ID \
    -e BUILD_NUMBER=$BUILD_NUMBER \
    -e UT_ENV=jenkins \
    -e UT_DB_PASS=$UT_DB_PASS \
    -e UT_MASTER_KEY=$UT_MASTER_KEY \
    -e CHROMATIC_PROJECT_TOKEN=$CHROMATIC_PROJECT_TOKEN \
    -e GITLAB_STATUS_TOKEN=$GITLAB_STATUS_TOKEN \
    -e GIT_COMMIT=$GIT_COMMIT \
    -e GITLAB_OA_LAST_COMMIT_ID=$GITLAB_OA_LAST_COMMIT_ID \
    -e GITLAB_OA_SOURCE_BRANCH=$GITLAB_OA_SOURCE_BRANCH \
    -e UT_MODULE=$UT_MODULE \
    -e GIT_URL=$GIT_URL \
    -e GIT_BRANCH=$GIT_BRANCH \
    -e BRANCH_NAME=$BRANCH_NAME \
    -e BUILD_CAUSE=$BUILD_CAUSE \
    -e DOCKER_USR=$DOCKER_USR \
    -e DOCKER_PSW=$DOCKER_PSW \
    -e TOOLS_URL=$IMPL_TOOLS_URL \
    -e IMPL_TOOLS_URL=$IMPL_TOOLS_URL \
    -e IMPL_TOOLS_USR=$IMPL_TOOLS_USR \
    -e IMPL_TOOLS_PSW=$IMPL_TOOLS_PSW \
    -e CHANGE_ID=$CHANGE_ID \
    -e ${UT_PREFIX}_db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_db__connection__encryptionPass="$encryptionPass" \
    -e ${UT_PREFIX}_db__connection__database=${UT_MODULE}-${UT_PROJECT}-${BRANCH_NAME//[\/\\]/-}-${BUILD_NUMBER}${DBSUFFIX} \
    -e ${UT_PREFIX}_utAudit__db__create__password=$UT_DB_PASS \
    -e ${UT_PREFIX}_utAudit__db__connection__database=${UT_MODULE}-audit-${UT_PROJECT}-${BRANCH_NAME//[\/\\]/-}-${BUILD_NUMBER}${DBSUFFIX} \
    -e ${UT_PREFIX}_utHistory__db__connection__database=${UT_MODULE}-history-${UT_PROJECT}-${BRANCH_NAME//[\/\\]/-}-${BUILD_NUMBER}${DBSUFFIX} \
    -e ${UT_PREFIX}_utHistory__db__create__password=$UT_DB_PASS \
    -e TAP_TIMEOUT=$TAP_TIMEOUT \
    --entrypoint=/bin/bash \
    --name ${UT_PROJECT}-${TEST_IMAGE_TAG} \
    ${UT_PROJECT}:${TEST_IMAGE_TAG} -c "(git checkout -- .dockerignore || true) && npm run jenkins" \
    || (docker rm ${UT_PROJECT}-${TEST_IMAGE_TAG} && false)
docker cp ${UT_PROJECT}-${TEST_IMAGE_TAG}:/app/package.json package.json
docker rm ${UT_PROJECT}-${TEST_IMAGE_TAG}

SONAR_BRANCH=-Dsonar.branch.name=${GIT_BRANCH#origin/}
if [[ ${CHANGE_ID} ]]; then
    SONAR_BRANCH="-Dsonar.pullrequest.key=${CHANGE_ID} -Dsonar.pullrequest.branch=${CHANGE_BRANCH#origin/} -Dsonar.pullrequest.base=${CHANGE_TARGET#origin/}"
fi

docker run --entrypoint=/bin/sh -i --rm -v $(pwd):/app nexus-dev.softwaregroup.com:5000/softwaregroup/sonar-scanner:3.2.0-alpine \
  -c "sonar-scanner \
  -Dsonar.host.url=https://sca.softwaregroup.com/ \
  -Dsonar.projectKey=${SONAR_PREFIX}${UT_PROJECT} \
  -Dsonar.projectName=${UT_PROJECT} \
  -Dsonar.projectVersion=1 \
  -Dsonar.projectBaseDir=/app \
  -Dsonar.links.ci=${BUILD_URL} \
  -Dsonar.links.scm=${REPO_URL} \
  -Dsonar.sources=. \
  -Dsonar.inclusions=**/*.js,**/*.ts,**/*.tsx \
  -Dsonar.exclusions=node_modules/**/*,coverage/**/*,test/**/*,tap-snapshots/**/*,dist/**/* \
  -Dsonar.tests=. \
  -Dsonar.test.inclusions=test/**/*.js,**/*.test.js,**/*.test.ts,**/*.test.tsx \
  -Dsonar.test.exclusions=node_modules/**/*,coverage/**/*,dist/**/* \
  -Dsonar.coverage.exclusions=ui/**/* \
  ${SONAR_BRANCH} \
  -Dsonar.login=${SONAR_SCA_USR} \
  -Dsonar.password=${SONAR_SCA_PSW} \
  -Dsonar.javascript.lcov.reportPaths=coverage/lcov.info \
  -Dsonar.working.directory=.lint/.scannerwork \
  && chown -R $(id -u):$(id -g) /app/.lint/.scannerwork"
if [[ $RELEASE && ${UT_IMPL} ]]; then
    TAG=${RELEASE//[\/\\]/-}
    if [ "$TAG" = "master" ]; then TAG="latest"; fi
    IMAGE_TAG=${TAG}-${EXECUTOR_NUMBER}
    docker build -t ${UT_PROJECT}:${IMAGE_TAG} . -f-<<EOF
        FROM ${UT_PROJECT}:${TEST_IMAGE_TAG}
        RUN npm prune --legacy-peer-deps --production
EOF
    docker build -t ${UT_PROJECT}-${IMAGE_TAG}-amd64 . -f-<<EOF
        FROM $IMAGE
        ${PREFETCH_PROD}
        RUN mkdir /var/lib/SoftwareGroup && chown -R node:node /var/lib/SoftwareGroup
        USER node
        COPY --chown=node:node --from=${UT_PROJECT}:${IMAGE_TAG} /app /app
        COPY --chown=node:node --from=${UT_PROJECT}:${IMAGE_TAG} /home/node/.cache/ms-playwright /home/node/.cache/ms-playwright
        WORKDIR /app
        COPY --chown=node:node dist dist
        COPY --chown=node:node package.json package.json
        ENTRYPOINT ["node", "index.js"]
        CMD ["server"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup.com:5001
    if [ "${ARMIMAGE}" ]; then
        docker build -t ${UT_PROJECT}-${IMAGE_TAG}-arm64 --platform linux/arm64 . -f-<<EOF
            FROM $ARMIMAGE
            ${PREFETCH_PROD}
            RUN mkdir /var/lib/SoftwareGroup && chown -R node:node /var/lib/SoftwareGroup
            USER node
            COPY --chown=node:node --from=${UT_PROJECT}:${IMAGE_TAG} --platform=$BUILDPLATFORM /app /app
            WORKDIR /app
            COPY --chown=node:node dist dist
            COPY --chown=node:node package.json package.json
            ENTRYPOINT ["node", "index.js"]
            CMD ["server"]
EOF
        docker tag ${UT_PROJECT}-${IMAGE_TAG}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG
        docker tag ${UT_PROJECT}-${IMAGE_TAG}-arm64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        docker rmi ${UT_PROJECT}:${IMAGE_TAG} ${UT_PROJECT}-${IMAGE_TAG}-amd64 ${UT_PROJECT}-${IMAGE_TAG}-arm64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        DOCKER_CLI_EXPERIMENTAL=enabled docker manifest create nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-amd64:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG
        DOCKER_CLI_EXPERIMENTAL=enabled docker manifest annotate nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}-arm64:$TAG --os linux --arch arm64 --variant v8
        DOCKER_CLI_EXPERIMENTAL=enabled docker manifest push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
    else
        docker tag ${UT_PROJECT}-${IMAGE_TAG}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
        docker push nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
        docker rmi ${UT_PROJECT}:${IMAGE_TAG} ${UT_PROJECT}-${IMAGE_TAG}-amd64 nexus-dev.softwaregroup.com:5001/ut/${UT_PROJECT}:$TAG
    fi
    if [ "${DEPLOY_TOKEN}" ]; then
        docker run -u node:node -i --rm \
            -v "$(pwd)/package.json:/app/package.json" \
            -e DEPLOY_TOKEN=$DEPLOY_TOKEN \
            -e DEPLOY_TAG=$TAG \
            ${UT_PROJECT}:${TEST_IMAGE_TAG} /bin/sh -c "npm run deploy" || true
    fi
fi

docker rmi ${UT_PROJECT}:${TEST_IMAGE_TAG}

SONAR_QUERY=${GIT_BRANCH#origin/}
SONAR_QUERY="&branch=${SONAR_QUERY//[\/\\]/%2F}"
if [[ ${CHANGE_ID} ]]; then
    SONAR_QUERY="&pullRequest=${CHANGE_ID}"
fi

sleep 30
docker run -u node:node -i --rm \
    --cap-add=SYS_ADMIN \
    -v "$(pwd)/.lint:/app/.lint" \
    nexus-dev.softwaregroup.com:5000/softwaregroup/capture-website --output=.lint/sonar.png --width=1067 --height=858 --scale-factor=0.6 \
    https://sca.softwaregroup.com/dashboard?id=${SONAR_PREFIX}${UT_PROJECT}${SONAR_QUERY}
