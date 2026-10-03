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
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Force every Android plugin module to compile against API 36.
//
// `file_picker` depends on `flutter_plugin_android_lifecycle`, which requires its
// consumers to compile against 36. Raising compileSdk in app/build.gradle.kts is
// NOT enough — each plugin module carries its own compileSdk (34, from the
// Flutter toolchain), so the build fails at :file_picker:checkReleaseAarMetadata
// naming the plugin rather than the app.
//
// This block must come BEFORE the `evaluationDependsOn(":app")` below. That call
// evaluates subprojects immediately, and Gradle then refuses a late
// afterEvaluate with "Cannot run Project.afterEvaluate(Action) when the project
// is already evaluated".
//
// compileSdk is compile-time only — it changes neither runtime behaviour
// (targetSdk) nor which handsets can install the app (minSdk).
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let {
            (it as com.android.build.gradle.BaseExtension).compileSdkVersion(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
