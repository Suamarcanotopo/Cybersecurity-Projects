// ©AngelaMos | 2026
// clean_hello.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct record {
    int id;
    char name[64];
    double score;
};

static void print_record(const struct record *r) {
    printf("[%04d] %-20s %.2f\n", r->id, r->name, r->score);
}

static int compare_records(const void *a, const void *b) {
    const struct record *ra = (const struct record *)a;
    const struct record *rb = (const struct record *)b;
    if (ra->score < rb->score) return 1;
    if (ra->score > rb->score) return -1;
    return strcmp(ra->name, rb->name);
}

int main(void) {
    struct record entries[] = {
        {1, "Alice",   92.5},
        {2, "Bob",     87.3},
        {3, "Charlie", 95.1},
        {4, "Diana",   88.0},
        {5, "Eve",     91.7},
    };
    size_t count = sizeof(entries) / sizeof(entries[0]);

    qsort(entries, count, sizeof(struct record), compare_records);

    puts("=== SORTED RECORDS ===");
    for (size_t i = 0; i < count; i++) {
        print_record(&entries[i]);
    }

    double total = 0.0;
    for (size_t i = 0; i < count; i++) {
        total += entries[i].score;
    }
    printf("\nAverage: %.2f\n", total / (double)count);

    return 0;
}
