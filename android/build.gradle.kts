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
// Some plugins (super_keyboard via super_editor) still hard-code an older
// compileSdk while newer plugin transitive deps require API 36 — force every
// Android subproject up to 36 (the Flutter default). Older plugin builds
// expose their android extension as a GroovyObject; newer-DSL projects are
// skipped (they are already on 36 via flutter.compileSdkVersion).
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            (ext as? groovy.lang.GroovyObject)?.setProperty("compileSdk", 36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}


tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
