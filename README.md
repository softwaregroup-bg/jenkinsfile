# Shared Jenkins library for UT framework

To use this shared library, create a file named `Jenkinsfile`
in the root of your project with the following contents:

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut ([
    buildImage: 'node:10.15.3-alpine',
    image: 'mhart/alpine-node:base-10.15.3',
    armimage: 'arm64v8/node:10.15.3-alpine'
])
```

Then in Jenkins server, create a job of type `Pipeline` or
`Multibranch Pipeline` and select `Pipeline script from SCM`
and configure it to pull from your project's repository.
