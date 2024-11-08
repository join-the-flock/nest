# Configuring the Environment

Before starting the development process, we are going to set up our environment. 
To do that, the following steps should be completed: 
1. Install necessary tools
1. Configure the Git environment
1. Sanity Check

## Tools
Given that the focus of this book is not on those tools, they will be listed 
with only enough information, adding any additional information as external 
resources.

- **Git**: Used as source version control. 
    - <a href="https://git-scm.com/downloads" target="_blank">Download and install</a>
    - <a href="https://git-scm.com/doc" target="_blank">Documentation</a>
        - <a href="https://git-scm.com/docs" target="_blank">Reference Manual</a>
        - <a href="https://git-scm.com/book/" target="_blank">Book</a>
        - <a href="https://training.github.com/" target="_blank">Cheat Sheet</a>
    - Important repositories: <a href="https://github.com/flutter/flutter" target="_blank">Flutter</a>, <a href="https://github.com/join-the-flock/flock" target="_blank">Flock</a>
- **Integrated Development Environment (IDE)**: there are a lot of IDEs out there, but two are very popular among flutter developers. Install the IDE with the *Flutter plugin/extensions* for each: 
    - <a href="https://docs.flutter.dev/tools/android-studio" target="_blank">Android Studio</a>
    - <a href="https://docs.flutter.dev/tools/vs-code" target="_blank">Visual Studio Code</a>
- **Python**: Some tools require that you have Python installed on your machine.
    - <a href="https://www.python.org/downloads/" target="_blank">Download and install</a>
- **Android Platform Tools**: Android SDK Platform-Tools is a component for the Android SDK. It includes tools that interface with the Android platform, primarily adb and fastboot. Although adb is required for Android app development, app developers will normally just use the copy Studio installs.
    - **Android Studio on Windows**: Usually, the Android SKD Platform-Tools are in the path: `C:\Users\<your_user>\AppData\Local\Android\Sdk\platform-tools`
    - **Activate those tools from your Android Studio** following the path `Tools/SDK Manager/Android SDK/SDK Tools`:
    ![Image of the Android Studio interface showing tools/SDK manager option to activate the android sdk platform tools](./assets/android_sdk_platform_tools.png)
    - <a href="https://developer.android.com/tools/releases/platform-tools" target="_blank">Download</a> if you are not using the version from your IDE.

    <!-- TODO Is there any other tool that you can remember? Maybe for flock. -->
    
## Configuring the Git Environment
The following tutorials show how to set up your git environment for both the
Original Flutter and the Flock repositories.  
### For Flutter
1. Clone the flutter/flutter repo using either SSH or HTTPS (SSH is recommended, but requires a working [SSH key](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/about-ssh) on your GitHub account):
      - SSH: `git clone git@github.com:flutter/flutter.git`
      - HTTPS: `git clone https://github.com/flutter/flutter.git`

1. Change into the directory of the cloned repository and rename the origin remote to upstream:
     1. `cd flutter`
     1. `git remote rename origin upstream`

1. [Fork the flutter/flutter repo](https://github.com/flutter/flutter/fork) into your own GitHub account.

1. Add your fork as the origin remote to your local clone either using SSH or HTTPS by replacing `<your_user>` with your GitHub account name:
     - SSH: `git remote add origin git@github.com:<your_user>/flutter.git`
     - HTTPS: `git remote add origin https://github.com/<your_user>/flutter.git`

1. Verify the upstream and origin repository you've specified for your clone.
      - `git remote -v`

1. Add the repo's `bin` directory to your [PATH](https://en.wikipedia.org/wiki/PATH_(variable)): e.g. on UNIX, using `export PATH="$PATH:$HOME/<path to flutter repository>/bin"`

    - If you already have a Flutter installation you will either need to remove it from your PATH, or use a full path whenever you are running `flutter` in this repository. If you have version solving errors when trying to run examples below, you are running a version of Flutter other than the one checked out here.

1. `flutter update-packages`

   This will recursively fetch all the Dart packages that
   Flutter depends on. If version solving failed, try `git fetch upstream` to update Flutter versions before `flutter update-packages`.


### For Flock
TODO: consider contributing writing this part.


## Sanity Check
After configuring the repository, it is useful to perform  initial
checks to ensure everything is set up correctly. We are going to run the tests
of the Framework. Then, we will run some examples.

### Running Tests



## References
- Flutter Contribution Guide: <a href="https://github.com/flutter/flutter/blob/master/CONTRIBUTING.md" target="_blank">CONTRIBUTING.md</a>
- Setting up the Framework Development Environment: <a href="https://github.com/flutter/flutter/blob/master/docs/contributing/Setting-up-the-Framework-development-environment.md" target="_blank">Setting-up-the-Framework-development-environment.md</a>
- Video tutorial on how to contribute to the Flutter Framework: <a href="https://www.youtube.com/watch?v=4yBgOBAOx_A" target="_blank">How to contribute to Flutter (The Boring Flutter Development Show, Ep. 53)</a>
