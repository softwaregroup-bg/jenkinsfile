# Shared Jenkins library for UT framework

To use this shared library, create a file named `Jenkinsfile`
in the root of your project with the following contents:

## For modules

Use this to build modules (`ut-*`):

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut buildImage: 'softwaregroup/ut-docker'
```

## For implementations

Use this to build implementations (`impl-*`):

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut buildImage: 'softwaregroup/impl-docker',
```

## Advanced usage

Use this to build also ARM image for implementations:

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut ([
    buildImage: 'softwaregroup/impl-docker',
    image: 'mhart/alpine-node:base-10.16.3',
    armimage: 'arm64v8/node:10.16.3-alpine'
])
```

Then in Jenkins server, create a job of type `Pipeline` or
`Multibranch Pipeline` and select `Pipeline script from SCM`
and configure it to pull from your project's repository.
