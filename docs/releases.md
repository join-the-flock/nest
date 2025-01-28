# Releases

The push workflow ```.github/workflows/push.yaml``` will automatically produce a release when changes are pushed into a branch.

## Getting Started

1. Configure a destination repository to push your Flock builds to by adding a repository variable named ```DESTINATION_REPO``` with the URL of the repository to push to (for example ```https://github.com/join-the-flock/flock```). 

2. Configure a repository secret in Github named ```REPO_WORKFLOW_PAT``` with a Personal Access Token. The access token must have permission to push to your Flutter or Flock repository (repo permissions for a classic token). To avoid issues pushing workflow updates, also add the ```workflow``` permission to the token.

3. By default the action will apply patches on top of whatever is found in a flutter branch with the same name and then push to a branch with the same name. For instance, if the workflow runs on a branch ```main``` it will push to a branch ```main``` in the destination flutter repo. If you would like to force Nest to use a specific source branch, add a ```FLUTTER_BASE_REF``` repository variable. Some people may desire to maintain a flutter repo which contains both flock and flutter refs. To add a prefix to the branch names used when pushing to the destination repo, add a ```FLOCK_REF_PREFIX``` repository variable. Setting this variable to ```flock-``` for example, will cause pushes to the nest branch ```main``` to create a flock branch ```flock-main``` in the destination respository.

## Making a Release

1. Create a branch in your nest repository. ```git checkout -b BRANCH_NAME```

2. Make sure that the patches folder contains the patches you would like to apply on top of this.

3. Push your branch to your nest repostory. ```git push origin BRANCH_NAME```

4. The push workflow will automatically pull down the flutter branch with the same name, apply the patches in your branch to it, test the branch to make sure that it still passes any tests, and then push to a branch on your destination flock repo with the same name if the tests pass. Note that the workflow will perform a force push to prevent failures when the patches are modified.