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

    // dash_bubble 2.0.0 ships an old AndroidManifest that declares its package
    // via the legacy `package=` attribute and no `namespace`, which newer AGP
    // rejects. Inject the namespace (and a modern compileSdk) before the module
    // is evaluated so we don't hand-patch pub-cache — this survives
    // `flutter pub get` and reproduces on the client's machine. Registered here
    // (before evaluationDependsOn forces evaluation) so afterEvaluate is valid.
    if (project.name == "dash_bubble") {
        project.afterEvaluate {
            val android = extensions.findByName("android")
            if (android != null) {
                val getNs = android.javaClass.getMethod("getNamespace")
                if (getNs.invoke(android) == null) {
                    android.javaClass
                        .getMethod("setNamespace", String::class.java)
                        .invoke(android, "dev.moaz.dash_bubble")
                }
                android.javaClass
                    .getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType)
                    .invoke(android, 34)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
