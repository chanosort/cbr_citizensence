allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Force all Flutter plugin subprojects to compile against SDK 36
// so they satisfy flutter_plugin_android_lifecycle's requirement.
subprojects {
    if (project.name != "app") {
        if (state.executed) {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.compileSdk = 36
        } else {
            afterEvaluate {
                extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}