plugins {
    `java-library`
    `maven-publish`
    signing
    id("com.diffplug.spotless") version "8.10.4"
}

group = "app.suiss"
version = "0.1.0"

val contracts = layout.projectDirectory.dir("../../contracts")
val conformance = layout.projectDirectory.dir("../../conformance")

val generator: SourceSet by sourceSets.creating

java {
    withSourcesJar()
    withJavadocJar()
}

dependencies {
    api("com.fasterxml.jackson.core:jackson-databind:2.22.4")
    "generatorImplementation"("com.fasterxml.jackson.dataformat:jackson-dataformat-yaml:2.22.4")
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

dependencyLocking {
    lockAllConfigurations()
    lockMode = LockMode.STRICT
}

tasks.withType<JavaCompile>().configureEach {
    options.release = 17
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-Xlint:all", "-Werror"))
}

tasks.withType<Javadoc>().configureEach {
    options.encoding = "UTF-8"
    (options as StandardJavadocDocletOptions).addBooleanOption("Xdoclint:all,-missing", true)
}

tasks.test {
    useJUnitPlatform()
    systemProperty("relay.conformance", conformance.asFile.canonicalPath)
    inputs.dir(conformance)
}

val generate by tasks.registering(JavaExec::class) {
    group = "build"
    description = "Regenerates the generated sources from the Relay contracts."
    classpath = generator.runtimeClasspath
    mainClass = "app.suiss.relay.generator.Generator"
    args(contracts.asFile.canonicalPath, layout.projectDirectory.dir("src/main/java").asFile.path)
}

tasks.register("resolveAll") {
    group = "help"
    description = "Resolves every resolvable configuration, for locking and verification."
    val resolvable = configurations.filter { it.isCanBeResolved }
    doLast {
        resolvable.forEach { it.resolve() }
    }
}

spotless {
    java {
        target("src/*/java/**/*.java")
        googleJavaFormat("1.36.1")
    }
}

tasks.configureEach {
    if (name.startsWith("spotless")) {
        mustRunAfter(generate)
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            artifactId = "esuiss-relay"
            from(components["java"])
            pom {
                name = "Relay server SDK"
                description = "Java client for the Relay notification and agent messaging API."
                url = "https://github.com/e-suiss/relay"
                licenses {
                    license {
                        name = "Apache-2.0"
                        url = "https://www.apache.org/licenses/LICENSE-2.0"
                    }
                }
                developers {
                    developer {
                        id = "e-suiss"
                        name = "Suiss"
                    }
                }
                scm {
                    url = "https://github.com/e-suiss/relay"
                    connection = "scm:git:https://github.com/e-suiss/relay.git"
                }
            }
        }
    }
    repositories {
        maven {
            name = "staging"
            url = uri(layout.buildDirectory.dir("staging"))
        }
    }
}

signing {
    val key = providers.environmentVariable("SIGNING_KEY")
    val password = providers.environmentVariable("SIGNING_PASSWORD")
    isRequired = key.isPresent
    if (key.isPresent) {
        useInMemoryPgpKeys(key.get(), password.orNull)
        sign(publishing.publications["maven"])
    }
}
