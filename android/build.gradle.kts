allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val projectPath = project.layout.projectDirectory.asFile.toPath().normalize()
    val rootPath = rootProject.layout.projectDirectory.asFile.toPath().normalize()
    val isInRepository = projectPath.startsWith(rootPath)
    val newSubprojectBuildDir: Directory = if (isInRepository) {
        newBuildDir.dir(project.name)
    } else {
        project.layout.projectDirectory.dir("build")
    }
    project.layout.buildDirectory.value(newSubprojectBuildDir)
    if (!isInRepository) {
        tasks.matching { it.name.contains("UnitTest") }.configureEach {
            enabled = false
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
