def call(Map params = [:]) {
    def buildImage = params.buildImage?:'nexus-dev.softwaregroup.com:5000/softwaregroup/ut-gallium'
    def image = params.image?:'nexus-dev.softwaregroup.com:5000/softwaregroup/deploy-gallium'
    def armimage = params.armimage?:''
    def scanner = [dashboardUrl:'https://sca.softwaregroup.com']
    def agentLabel = (env.JOB_NAME.substring(0,3) == 'ut-') ? 'ut5-slaves' : 'implementation-slaves'
    def sonarCoverageExclusions = params.sonarCoverageExclusions?:'ui/**/*'
    def repoUrl
    pipeline {
        options { disableConcurrentBuilds abortPrevious: true }
        agent { label 'implementation-slaves' }
        environment {
            BUILD_DATE = new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        stages {
            stage('indexing') {
                when { triggeredBy 'BranchIndexingCause' }
                steps {
                    script {
                        currentBuild.displayName = '#' + currentBuild.number + ' - abort indexing'
                        currentBuild.result = 'ABORTED'
                    }
                }
            }
            stage('build') {
                // when { not { changelog "^[ci.skip]" }}
                when {not { triggeredBy 'BranchIndexingCause' }}
                environment {
                    JOB_TYPE = 'pipeline'
                    UT_DB_PASS = credentials('UT_DB_PASS')
                    UT_MASTER_KEY = credentials('UT_MASTER_KEY')
                    CHROMATIC_PROJECT_TOKEN = credentials('CHROMATIC_PROJECT_TOKEN')
                    DEPLOY_TOKEN = credentials('DEPLOY_TOKEN')
                    GITLAB_STATUS_TOKEN = credentials('GITLAB_STATUS_TOKEN')
                    encryptionPass = credentials('UT_DB_ENCRYPTION_PASS')
                    DOCKER = credentials('dockerPublisher')
                    SONAR_SCA = credentials('SONAR_SCA')
                    IMPL_TOOLS_URL = credentials('IMPL_TOOLS_URL')
                    IMPL_TOOLS = credentials('IMPL_TOOLS')
                    BUILD_IMAGE = "${buildImage}"
                    IMAGE = "${image}"
                    ARMIMAGE = "${armimage}"
                    SONAR_COVERAGE_EXCLUSIONS = "${sonarCoverageExclusions}"
                }
                steps {
                    // sh 'printenv | sort'
                    script {
                        pkgjson = readJSON file: 'package.json'
                        repoUrl = pkgjson.repository.url
                        currentBuild.displayName = '#' + currentBuild.number + ' - ' + env.GIT_BRANCH
                        env.REPO_URL = 'https://' + repoUrl.replaceAll(/^git@|.git$/, '').replace(':', '/') + '''/tree/''' + (env.CHANGE_ID ? env.CHANGE_BRANCH : env.GIT_BRANCH)
                    }
                    ansiColor('xterm') {
                        sh(libraryResource('ut.sh'))
                    }
                }
                post {
                    always {
                        sh 'docker rmi -f $(docker images -q -f "dangling=true") || true'
                        script {
                            def files = findFiles(glob:'.lint/result.json')
                            if (files) {
                                pkg = readJSON file: files[0].path
                                currentBuild.displayName = '#' + currentBuild.number + ' - ' + env.GIT_BRANCH + ' : ' + pkg.version
                            }
                            files = findFiles(glob:'.lint/.scannerwork/report-task.txt')
                            if (files) {
                                scanner = readProperties file: files[0].path, defaults: [dashboardUrl:'https://sca.softwaregroup.com']
                            }
                        }
                        recordIssues enabledForFailure: true, ignoreFailedBuilds: false, tools: [checkStyle(pattern: '.lint/lint*.xml'), junitParser(pattern: '.lint/jlint*.xml')]
                        step([$class: "TapPublisher", testResults: ".lint/tap.txt", verbose: false, enableSubtests: true, planRequired: false])
                        cobertura coberturaReportFile: 'coverage/cobertura-coverage.xml', failNoReports: false
                        perfReport sourceDataFiles: '.lint/load/*.csv', failBuildIfNoResultFile: false, compareBuildPrevious: true
                        xunit(tools:[GoogleTest(deleteOutputFiles: true, failIfNotNew: true, pattern: '.lint/*unit.xml', skipNoTestFiles: true, stopProcessingIfError: false)])
                        publishHTML([
                            reportName: 'Code coverage',
                            reportTitles: '',
                            reportDir: 'coverage/lcov-report',
                            reportFiles: 'index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        publishHTML([
                            reportName: 'Storybook',
                            reportTitles: '',
                            reportDir: '.lint/storybook',
                            reportFiles: 'index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        publishHTML([
                            reportName: 'Documentation',
                            reportTitles: 'API',
                            reportDir: '.lint/doc',
                            reportFiles: 'aa/api/server/index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        publishHTML([
                            reportName: 'Bundle analyzer',
                            reportTitles: 'Bundle analyzer',
                            reportDir: '.lint/bundle',
                            reportFiles: 'index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        publishHTML([
                            reportName: 'Playwright',
                            reportTitles: 'Playwright',
                            reportDir: '.lint/playwright-unit',
                            reportFiles: 'index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        publishHTML([
                            reportName: 'Help',
                            reportTitles: 'Help',
                            reportDir: 'dist/help',
                            reportFiles: 'index.html',
                            allowMissing: true,
                            alwaysLinkToLastBuild: true,
                            keepAll: true
                        ])
                        emailext(
                            mimeType: 'text/html',
                            body: '''<h1>Jenkins build ''' + repoUrl.replaceAll(/^[^\/]*\/|.git$/, "") + ''' ${BUILD_DISPLAY_NAME}</h1>
<h2><b>Status</b>: ${BUILD_STATUS}</h2>
<div style="float:right; width: 50%;">
    <img src="cid:sonar.png" />
</div>
<b>Trigger</b>:  ${CAUSE}<br>
<b>Job</b>: ${JOB_URL}<br>
<b>Branch</b>: ''' + repoUrl.replaceAll(/^git@|.git$/, '').replace(':', '/') + '''/tree/''' + (env.CHANGE_ID ? env.CHANGE_BRANCH : env.GIT_BRANCH) + '''<br>
<b>MR/PR</b>: ${CHANGE_URL}<br>
<b>Summary</b>: ${BUILD_URL}<br>
<b>Console</b>: ${BUILD_URL}console<br>
<b>Workspace</b>: ${BUILD_URL}/execution/node/4/ws<br>
<b>Sonar</b>: ''' + scanner.dashboardUrl + '''<br>
<b>Checkstyle</b>: ${CHECKSTYLE_RESULT}<br>
<b>Changes</b>:<pre>
${CHANGES}
</pre>
<b>Tests</b>:<pre>
${FILE,path=".lint/test.txt"}
</pre>
<b>npm audit</b>:${FILE,path=".lint/audit.html"}
            ''',
                            recipientProviders: [[$class: 'CulpritsRecipientProvider'],[$class: 'RequesterRecipientProvider']],
                            attachmentsPattern: '.lint/sonar*.png',
                            subject: 'Build ${BUILD_STATUS} in Jenkins: ' + repoUrl.replaceAll(/^[^\/]*\/|.git$/, "") + ' ${BUILD_DISPLAY_NAME} (' + currentBuild.durationString +')'
                        )
                    }
                }
            }
        }
    }
}