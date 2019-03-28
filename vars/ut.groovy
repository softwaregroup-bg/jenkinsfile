def call(
    buildImage = 'node:8.15.0-alpine',
    image = 'mhart/alpine-node:base-8.15.0'
) {
    pipeline {
        agent { label 'implementation-slaves' }
        stages {
            stage('build') {
                environment {
                    JOB_TYPE = 'pipeline'
                    UT_DB_PASS = credentials('UT_DB_PASS')
                    encryptionPass = credentials('UT_DB_ENCRYPTION_PASS')
                    DOCKER = credentials('dockerPublisher')
                    BUILD_IMAGE = "${buildImage}"
                    IMAGE = "${image}"
                }
                steps {
                    // sh 'printenv | sort'
                    script {
                        currentBuild.displayName = '#' + currentBuild.number + ' - ' + env.gitlabBranch
                    }
                    ansiColor('xterm') {
                        sh(libraryResource('ut.sh'))
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
                        scanner = readProperties file: files[0].path, defaults: [dashboardUrl:'https://sonar.softwaregroup.com']
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