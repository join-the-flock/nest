# The Flutter Framework Book - README
This tutorial shows how to build "The Flutter Framework Book" and how to update its contents.

## Build and Run
1. Install mdBook (choose one):
    - Download a precompiled binary: [releases](https://github.com/rust-lang/mdBook/releases), or
    - (advanced) Install using cargo: `cargo install mdbook`
2. Build and run the book locally from the **documentation/books/the_flutter_framework_book** path:
```bash
mdbook serve --open
```

3. Build the book:
```bash
mdbook build
```

## Contribute
The book structure is very simple: 
```
the_flutter_framework_book/
├───book/
├───src/
│   ├───<chapter1>.md
│   ├───<chapter2>.md
│   ├─...
│   └───SUMMARY.md
├───.gitignore
├───book.toml
└───README.md
```
- `book/`: The directory that contains the build. It is ignored by Git.
- `src/`: The directory that contains the book content. Each chapter is a markdown file with a name different from `SUMMARY.md`.
- `SUMMARY.md`: The markdown file that contains the summary of the book. Each chapter is added as a markdown link in a tree structure.
- `.gitignore`: Contains files/directories ignored by Git.
- `book.toml`: Contains configurations and metadata about the book.
- `README.md`: The file that you are reading right now.

### Edit the content of a chapter
1. (optional) Build the book and start serving it locally to see the updates in real time:
```bash
mdbook serve --open
```

2. Choose the desired chapter to add content.
- Suppose that we have the following structure in the `SUMMARY.md`:
```md
# Summary

- [Chapter 1](./chap1.md)
    - [Sub-chapter 1](./sub_chap1.md)
- [Chapter 2](./chap2.md)
- [Chapter 3](./chap3.md)
```

- To edit the content of **Chapter 2**, for example, you need to edit the file: `the_flutter_framework_book/src/chap2.md`. 


### Change the structure of the book
Other than changing chapters, it is possible to add new ones or to delete existing ones.

1. (optional) Build the book and start serving it locally to see the updates in real time:
```bash
mdbook serve --open
```

2. Choose the desired chapter to add content.
- Suppose that we have the following structure in the `SUMMARY.md`:
```md
# Summary

- [Chapter 1](./chap1.md)
    - [Sub-chapter 1](./sub_chap1.md)
- [Chapter 2](./chap2.md)
- [Chapter 3](./chap3.md)
```

- Change the structure of the `SUMMARY.md` and the build will automatically create any new markdown file that is necessary. For example, in the following structure, the **Chapter 4** was added and the subsection for **Chapter 1** was removed. 


```md
# Summary

- [Chapter 1](./chap1.md)
- [Chapter 2](./chap2.md)
- [Chapter 3](./chap3.md)
- [Chapter 4](./chap4.md)
```


# Helpful Links
- [mdBook documentation](https://rust-lang.github.io/mdBook/index.html)
- [mdBook releases](https://github.com/rust-lang/mdBook/releases)
- [cargo installation](https://doc.rust-lang.org/cargo/getting-started/installation.html)