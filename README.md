# Shared Jenkins library for UT framework

To use this shared library, create a file named `Jenkinsfile`
in the root of your project with the following contents:

## For modules

Use this to build modules (`ut-*`):

```groovy
library identifier: 'jenkinsfile@jod', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut buildImage: 'nexus-dev.softwaregroup.com:5000/softwaregroup/ut-jod'
```

## For implementations

Use this to build implementations (`impl-*`):

```groovy
library identifier: 'jenkinsfile@jod', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/softwaregroup-bg/jenkinsfile.git'
])

ut buildImage: 'nexus-dev.softwaregroup.com:5000/softwaregroup/impl-jod'
```
