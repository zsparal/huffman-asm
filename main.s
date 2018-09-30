.intel_syntax noprefix

# System V calling convention cheatsheet
# Params: rdi, rsi, rdx, rcx, r8, r9, xmm0-7
# Return: rax (int 64 bits), rax:rdx (int 128 bits), xmm0 (float)
# Callee cleanup: rbx, rbp, r12-15
# Scratch: rax, rdi, rsi, rdx, rcx, r8, r9, r10, r11 

.section .rodata
  leaf_fmt:   .string "%2$c: %1$d\n"
  branch_fmt: .string "BR: %d\n"
  text:       .string "bibbity bobbity"

  .equ tree_left,  0
  .equ tree_right, 8
  .equ tree_count, 16
  .equ tree_value, 20
  .equ tree_size,  24

  .equ heap_data, 0
  .equ heap_len,  8
  .equ heap_cap,  12
  .equ heap_size, 16

.section .text
  .global main
  .extern printf, calloc, malloc, realloc

main:
  mov    rdi, OFFSET text
  call   generate_tree
  mov    rdi, rax
  call   print_tree
  xor    rax, rax
  ret

# rdi - Huffman-tree root (ptr)
generate_codebook:
  ret


# rdi - text
# RET rax - Huffman-tree root (ptr)
generate_tree:
  push   r12
  push   r13
  sub    rsp, 1056                          # 1024 bytes for the char counts, 16 bytes for the heap, 8 extra bytes to align to 16-bytes
  mov    r12, rdi                           # Save the text to a register that won't be clobbered
  xor    rax, rax                           # Create the 256-length count array for each possible "char" value
  mov    rcx, 128
  lea    rdi, QWORD PTR [rsp + 16]
  rep    stosq
generate_tree_count_chars:
  mov    al, BYTE PTR [r12]
  test   al, al
  jz     generate_tree_construct_heap
  inc    DWORD PTR [rsp + 16 + 4*rax]
  inc    r12
  jmp    generate_tree_count_chars
generate_tree_construct_heap:
  xorps  xmm0, xmm0                         # Generate the zeroed heap
  movaps XMMWORD PTR [rsp], xmm0
  mov    r12, 255                           # The loop counter
  test   r12, r12                           # Check if we reached zero (on subsequent iterations "dec" sets the correct flag)
generate_tree_leaves:
  jl     generate_tree_branches             # If not then it's time to generate the branches
  mov    r13d, DWORD PTR [rsp + 16 + 4*r12] # Load the count at the ith position
  test   r13d, r13d                         # And check if it's zero
  jz     generate_tree_leaves_counters      # If it is we can skip this iteration
  mov    rdi, 1                             # If not, we need to allocate a new leaf node
  mov    rsi, tree_size                     
  call   calloc
  mov    DWORD PTR [rax + tree_value], r12d # Save the value and the count to the tree
  mov    DWORD PTR [rax + tree_count], r13d
  mov    rdi, rsp                           # Then push it onto the heap
  mov    rsi, rax
  call   heap_push
generate_tree_leaves_counters:
  dec    r12                                # Increment the loop counter and start over
  jmp    generate_tree_leaves
generate_tree_branches:
  cmp    DWORD PTR [rsp + heap_len], 1      # Check if there are still at least two elements in the heap
  jle    generate_tree_done                 # If not, we're done
  mov    rdi, rsp                           # Get the left child
  call   heap_pop
  mov    r12, rax
  mov    rdi, rsp                           # Get the right child
  call   heap_pop
  mov    r13, rax
  mov    rdi, tree_size                     # Create the new tree node, the pointer to it will be in rax
  call   malloc
  mov    ecx, DWORD PTR [r12 + tree_count]  # The new node's count: left count + right count
  add    ecx, DWORD PTR [r13 + tree_count]
  mov    QWORD PTR [rax + tree_left], r12   # Save the new node's fields: left, right, count (leave value unititialized, it shouldn't be used with branch nodes)
  mov    QWORD PTR [rax + tree_right], r13
  mov    DWORD PTR [rax + tree_count], ecx
  mov    rdi, rsp                           # Add the branch to the heap
  mov    rsi, rax
  call   heap_push
  jmp    generate_tree_branches
generate_tree_done:
  mov    rdi, rsp                           # The tree's root will be in rax after the pop
  call   heap_pop
  mov    r12, rax
  mov    rdi, [rsp]                         # Free the heap
  call   free
  mov    rax, r12                           # And return the tree root
  add    rsp, 1056
  pop    r13
  pop    r12
  ret

# rdi - heap ptr
# rsi - tree ptr
heap_push:
  mov    rax, QWORD PTR [rdi + heap_data]   # We load the heap's data ptr, length and capacity to the respective registers
  mov    edx, DWORD PTR [rdi + heap_cap]    # Load the current capacity
  cmp    DWORD PTR [rdi + heap_len], edx    # If length == capacity we have to grow the heap
  jne    heap_push_add
heap_push_grow:
  mov    r8d, 4                             # Load the initial capacity
  lea    edx, [edx + edx]                   # Calculate 2 * current capacity
  test   eax, eax                           # Check if the data ptr is null
  cmovne r8d, edx                           # And if it wasn't, update the capacity to the doubled one
  mov    DWORD PTR [rdi + heap_cap], r8d    # Save the new capacity
  push   rdi                                # Save the registers we don't want realloc to clobber   
  push   rsi
  mov    rdi, rax                           # Set up the parameters for realloc: data ptr, target size
  mov    rsi, r8
  shl    rsi, 3                             # Realloc expects the size in bytes but we store them as a count. Multiply by the size of a tree pointer
  call   realloc                            # After this point the correct data ptr (either the original or the realloc'ed one) will be in rax
  pop    rsi                                
  pop    rdi
  mov    QWORD PTR [rdi + heap_data], rax   # Save the new data ptr
heap_push_add:
  mov    ecx, DWORD PTR [rdi + heap_len]    # Load the current length
  lea    edx, [ecx + 1]                     # First, calculate the new length (length + 1)
  mov    DWORD PTR [rdi + heap_len], edx    # Then save it
  mov    QWORD PTR [rax + 8*rcx], rsi       # And finally add the new value at the end of the array
heap_push_sift_up:
  test   rcx, rcx                           # Test if we got to the root (index == 0)
  jz     heap_push_done
  lea    rdx, [rcx - 1]                     # Calculate the parent index: (index - 1) / 2
  shr    rdx, 1
  lea    r8, [rax + 8*rcx]                  # Get the pointer to the current and parent elements
  lea    r9, [rax + 8*rdx]              
  mov    r10, QWORD PTR [r8]                # Load the current and the parent elements
  mov    r11, QWORD PTR [r9]                          
  mov    esi, DWORD PTR [r10 + tree_count]  # Load the current tree's count
  cmp    DWORD PTR [r11 + tree_count], esi  # If parent count <= current count
  jle    heap_push_done                     # Then we're done
  mov    DWORD PTR [r8d], r11d              # Otherwise swap the two elements
  mov    DWORD PTR [r9d], r10d
  mov    rcx, rdx
  jmp    heap_push_sift_up
heap_push_done:
  ret

# rdi - heap ptr
# RET rax - tree ptr
heap_pop:
  mov    r8d, DWORD PTR [rdi + heap_len]    # Load the heap's length 
  test   r8d, r8d                           # If it's 0 then the heap's empty
  jz     heap_empty
  mov    rdx, [rdi + heap_data]             # Get the heap's data ptr
  mov    rax, QWORD PTR [rdx]               # The return value will be the tree's current root
  lea    r8d, [r8d - 1]                     # Calculate the new length
  mov    DWORD PTR [rdi + heap_len], r8d    # And save it
  mov    rsi, QWORD PTR [rdx + 8*r8]        # Load the element we're going to swap with the root
  mov    QWORD PTR [rdx], rsi               # Swap the root and the last element
  mov    QWORD PTR [rdx + 8*r8], rax
  xor    r9, r9                             # The loop index
heap_pop_sift_down:
  mov    rcx, r9                            # Save the target index at the start of the loop
  lea    r10, [r9 + r9 + 1]                 # The left child index
  lea    r11, [r9 + r9 + 2]                 # The right child index
  cmp    r10, r8
  jge    heap_pop_check_right
  mov    rdi, QWORD PTR [rdx + 8*r10]       # Load the left child
  mov    rsi, QWORD PTR [rdx + 8*rcx]       # Load the target     
  mov    esi, DWORD PTR [rsi + tree_count]  # Load the target tree count
  cmp    DWORD PTR [rdi + tree_count], esi  # If the left tree count < target tree count
  jge    heap_pop_check_right
  mov    rcx, r10
heap_pop_check_right:
  cmp    r11, r8
  jge    heap_pop_compare_indices
  mov    rdi, QWORD PTR [rdx + 8*r11]       # Load the right child
  mov    rsi, QWORD PTR [rdx + 8*rcx]       # Load the target     
  mov    esi, DWORD PTR [rsi + tree_count]  # Load the target tree count
  cmp    DWORD PTR [rdi + tree_count], esi  # If the right tree count < target tree count
  jge    heap_pop_compare_indices
  mov    rcx, r11
heap_pop_compare_indices:
  cmp    r9, rcx                            # If the target index == current index we're done
  je     heap_pop_done
  mov    rdi, QWORD PTR [rdx + 8*r9]        # Otherwise we swap the values
  mov    rsi, QWORD PTR [rdx + 8*rcx]
  mov    QWORD PTR [rdx + 8*r9], rsi
  mov    QWORD PTR [rdx + 8*rcx], rdi
  mov    r9, rcx
  jmp    heap_pop_sift_down
heap_pop_done:
  ret
heap_empty:
  xor    rax, rax                           # Return a null pointer to indicate the heap was empty
  ret

# rdi - tree ptr
print_tree:
  push   rbx                                
  mov    rbx, rdi                           # Save the parameter in a register we can reuse during recursion
print_tree_main:                            # Printing the right subtree is a tail call so we need a label after the setup part
  mov    rdi, QWORD PTR [rbx + tree_left]   # Check if the left branch is null
  test   rdi, rdi
  jz     print_tree_leaf                    # If it is then it _might_ be a leaf, jump to that part
  call   print_tree                         # If it is not, print it
  jmp    print_tree_branch                  # At this point we know we're not printing a leaf
print_tree_leaf:
  mov    rdi, OFFSET leaf_fmt               # Load the format string for leaves
  cmp    QWORD PTR [rbx + tree_right], 0    # Check if the node is actually a leaf
  jz     print_tree_current                 # And if it is, keep the leaf format string
print_tree_branch:
  mov    rdi, OFFSET branch_fmt
print_tree_current:
  mov    esi, DWORD PTR [rbx + tree_count]  # Print the current node
  mov    edx, DWORD PTR [rbx + tree_value]
  xor    rax, rax
  call   printf
  mov    rbx, [rbx + tree_right]            # Load the right child
  test   rbx, rbx
  jnz    print_tree_main                    # And if it's not null, print it
  pop    rbx
  ret
