def call() {
    pipeline {
        agent { label 'implementation-slaves' }
        stages {
            stage('build') {
                environment {
                    JOB_TYPE = 'pipeline'
                    UT_DB_PASS = credentials('UT_DB_PASS')
                    encryptionPass = credentials('UT_DB_ENCRYPTION_PASS')
                    DOCKER = credentials('dockerPublisher')
                }
                steps {
                    // sh 'printenv | sort'
                    script {
                        currentBuild.displayName = '#' + currentBuild.number + ' - ' + env.gitlabBranch
                    }
                    ansiColor('xterm') {
                        sh '''#!/bin/bash
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
FROM node:8.15.0-alpine
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
  -Dsonar.host.url=https://sonar.softwaregroup-bg.com/ \
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
FROM mhart/alpine-node:base-8.15.0
COPY --from=${JOB_NAME}:prod /app /app
WORKDIR /app
CMD ["node", "index.js"]
EOF
    echo "$DOCKER_PSW" | docker login -u "$DOCKER_USR" --password-stdin nexus-dev.softwaregroup-bg.com:5001
    docker tag ${JOB_NAME} nexus-dev.softwaregroup-bg.com:5001/ut/${JOB_NAME}:latest
    docker push nexus-dev.softwaregroup-bg.com:5001/ut/${JOB_NAME}:latest
    docker rmi ${JOB_NAME}:prod ${JOB_NAME} nexus-dev.softwaregroup-bg.com:5001/ut/${JOB_NAME}:latest
fi'''
                    }
                }
            }
        }
        post {
            always {
                sh 'docker rmi -f $(docker images -q -f "dangling=true") || true'
                script {
                    def files = findFiles(glob:'.lint/result.json')
                    if (files) {
                        pkg = readJSON file: files[0].path
                        currentBuild.displayName = '#' + currentBuild.number + ' - ' + env.gitlabBranch + ' : ' + pkg.version
                    }
                    files = findFiles(glob:'.scannerwork/report-task.txt')
                    if (files) {
                        scanner = readProperties file: files[0].path, defaults: [dashboardUrl:'https://sonar.softwaregroup-bg.com']
                    }
                }
                checkstyle pattern: '.lint/lint*.xml', canRunOnFailed: true
                step([$class: "TapPublisher", testResults: ".lint/tap.txt", verbose: false, enableSubtests: true, planRequired: false])
                cobertura coberturaReportFile: 'coverage/cobertura-coverage.xml', failNoReports: false
                xunit(tools:[GoogleTest(deleteOutputFiles: true, failIfNotNew: true, pattern: '.lint/xunit.xml', skipNoTestFiles: true, stopProcessingIfError: false)])
                publishHTML([
                    reportName: 'Code coverage',
                    reportTitles: '',
                    reportDir: 'coverage/lcov-report',
                    reportFiles: 'index.html',
                    allowMissing: true,
                    alwaysLinkToLastBuild: true,
                    keepAll: true
                ])
                emailext(
                    mimeType: 'text/html',
                    body: '''<h1>Jenkins build ${JOB_NAME} ${BUILD_DISPLAY_NAME}</h1>
    <h2><b>Status</b>: ${BUILD_STATUS}</h2>
    <b>Trigger</b>:  ${CAUSE}<br>
    <b>Job</b>: ${JOB_URL}<br>
    <b>Summary</b>: ${BUILD_URL}<br>
    <b>Console</b>: ${BUILD_URL}/console<br>
    <b>Workspace</b>: ${BUILD_URL}/execution/node/3/ws<br>
    <b>Sonar</b>: ''' + scanner.dashboardUrl + '''<br>
    <b>Checkstyle</b>: ${CHECKSTYLE_RESULT}<br>
    <b>Changes</b>:<pre>
    ${CHANGES}
    </pre>
    <b>Tests</b>:<pre>
    ${FILE,path=".lint/test.txt"}
    </pre>
    ''',
                    recipientProviders: [[$class: 'CulpritsRecipientProvider'],[$class: 'RequesterRecipientProvider']],
                    subject: 'Build ${BUILD_STATUS} in Jenkins: ${JOB_NAME} ${BUILD_DISPLAY_NAME} (' + currentBuild.durationString +')'
                )
            }
            failure {
                updateGitlabCommitStatus name: 'build', state: 'failed'
            }
            success {
                updateGitlabCommitStatus name: 'build', state: 'success'
            }
        }
    }
}