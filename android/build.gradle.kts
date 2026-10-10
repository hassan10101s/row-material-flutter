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
subprojects {
    project.evaluationDependsOn(":app")
}

// Some Flutter plugins (e.g. file_picker 8.x) still pin `compileSdk 34`
// while current AndroidX libraries (`flutter_plugin_android_lifecycle`)
// refuse to compile consumers against anything below 36, failing the build
// at `:plugin:checkDebugAarMetadata`. Compiling a plugin against a newer SDK
// changes no runtime behavior — targetSdk/minSdk are untouched — it only
// satisfies the metadata check. Registered in `beforeProject` so the
// `afterEvaluate` below is always legal (a bare `subprojects {
// afterEvaluate }` blows up on force-evaluated projects), and it still runs
// after each plugin's own `android { compileSdk ... }` block, so this wins.
// Kept here (not in the pub cache) so `flutter pub get` can never wipe it.
gradle.beforeProject {
    afterEvaluate {
        plugins.withId("com.android.library") {
            extensions.configure<com.android.build.api.dsl.LibraryExtension> {
                compileSdk = 36
            }
        }
        plugins.withId("com.android.application") {
            extensions.configure<com.android.build.api.dsl.ApplicationExtension> {
                compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
