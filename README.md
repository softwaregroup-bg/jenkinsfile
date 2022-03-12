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

ut buildImage: 'nexus-dev.softwaregroup.com:5000/softwaregroup/ut-gallium'
```

## For implementations

Use this to build implementations (`impl-*`):

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut buildImage: 'nexus-dev.softwaregroup.com:5000/softwaregroup/impl-gallium'
```

It will build implementation image based on
[mhart/alpine-node:slim-14.15.3](https://hub.docker.com/r/mhart/alpine-node/tags?page=1&name=slim-14.15.3)

To build for node 12, use:

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut(
    buildImage: 'nexus-dev.softwaregroup.com:5000/softwaregroup/impl-gallium',
    image: 'nexus-dev.softwaregroup.com:5000/softwaregroup/alpine-node:slim-12.16.3'
)
```

## Advanced usage

Use this to build also ARM image for implementations:

```groovy
library identifier: 'jenkinsfile@master', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut ([
    buildImage: 'softwaregroup/impl-gallium',
    image: 'mhart/alpine-node:base-14.15.3',
    armimage: 'arm64v8/node:14.15.3-alpine'
])
```

Then in Jenkins server, create a job of type `Pipeline` or
`Multibranch Pipeline` and select `Pipeline script from SCM`
and configure it to pull from your project's repository.
