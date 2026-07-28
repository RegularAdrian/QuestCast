plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val questCastKeystorePath = providers.environmentVariable("QUESTCAST_KEYSTORE")
val questCastStorePassword = providers.environmentVariable("QUESTCAST_STORE_PASSWORD")
val questCastKeyPassword = providers.environmentVariable("QUESTCAST_KEY_PASSWORD")

android {
    namespace = "com.apctv.questcast"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.apctv.questcast"
        minSdk = 29
        targetSdk = 35
        versionCode = 2
        versionName = "0.2"
    }

    signingConfigs {
        create("release") {
            if (questCastKeystorePath.isPresent && questCastStorePassword.isPresent) {
                storeFile = file(questCastKeystorePath.get())
                storePassword = questCastStorePassword.get()
                keyAlias = "questcast-release"
                keyPassword = questCastKeyPassword.orElse(questCastStorePassword).get()
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.16.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
}
