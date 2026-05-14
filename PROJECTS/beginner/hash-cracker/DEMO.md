<!-- ©AngelaMos | 2026 -->
<!-- DEMO.md -->

<div align="center">

```ruby
██╗  ██╗ █████╗ ███████╗██╗  ██╗ ██████╗██████╗  █████╗  ██████╗██╗  ██╗███████╗██████╗
██║  ██║██╔══██╗██╔════╝██║  ██║██╔════╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██╔════╝██╔══██╗
███████║███████║███████╗███████║██║     ██████╔╝███████║██║     █████╔╝ █████╗  ██████╔╝
██╔══██║██╔══██║╚════██║██╔══██║██║     ██╔══██╗██╔══██║██║     ██╔═██╗ ██╔══╝  ██╔══██╗
██║  ██║██║  ██║███████║██║  ██║╚██████╗██║  ██║██║  ██║╚██████╗██║  ██╗███████╗██║  ██║
╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝
```

**Demo & Preview**

<br>

<a href="https://github.com/CarterPerez-dev/Cybersecurity-Projects/tree/main/PROJECTS/beginner/hash-cracker">
  <img src="https://img.shields.io/badge/C++23-Multi--threaded-00599C?style=for-the-badge&logo=cplusplus&logoColor=white" alt="C++23"/>
</a>

<br>

```ruby
./install.sh    →    hashcracker --hash <hash> --wordlist <list>
```

<br>

[Dictionary Attack](#dictionary-attack) · [Rule-Based Mutations](#rule-based-mutations)

</div>

---

### Dictionary Attack

Memory-mapped wordlist scan with auto-detected hash type, work-partitioned across all cores, with live progress bar and h/s throughput

![Dictionary Attack](assets/dictionary.png)

---

### Rule-Based Mutations

Mutation rules expand a 10K wordlist into 20.1M candidates with capitalize, leet, digit-append, reverse, and toggle-case transforms applied per word

![Rule-Based Mutations](assets/rules.png)
