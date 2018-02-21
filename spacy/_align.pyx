# cython: infer_types=True
'''Do Levenshtein alignment, for evaluation of tokenized input.

Random notes:

  r i n g
  0 1 2 3 4
r 1 0 1 2 3
a 2 1 1 2 3
n 3 2 2 1 2
g 4 3 3 2 1

0,0: (1,1)=min(0+0,1+1,1+1)=0 S
1,0: (2,1)=min(1+1,0+1,2+1)=1 D
2,0: (3,1)=min(2+1,3+1,1+1)=2 D
3,0: (4,1)=min(3+1,4+1,2+1)=3 D
0,1: (1,2)=min(1+1,2+1,0+1)=1 D
1,1: (2,2)=min(0+1,1+1,1+1)=1 S
2,1: (3,2)=min(1+1,1+1,2+1)=2 S or I
3,1: (4,2)=min(2+1,2+1,3+1)=3 S or I
0,2: (1,3)=min(2+1,3+1,1+1)=2 I
1,2: (2,3)=min(1+1,2+1,1+1)=2 S or I
2,2: (3,3)
3,2: (4,3)
At state (i, j) we're asking "How do I transform S[:i+1] to T[:j+1]?"

We know the costs to transition:

S[:i]   -> T[:j]   (at D[i,j])
S[:i+1] -> T[:j]   (at D[i+1,j])
S[:i]   -> T[:j+1] (at D[i,j+1])
    
Further, we now we can tranform:
S[:i+1] -> S[:i] (DEL) for 1,
T[:j+1] -> T[:j] (INS) for 1.
S[i+1]  -> T[j+1] (SUB) for 0 or 1

Therefore we have the costs:
SUB: Cost(S[:i]->T[:j])   + Cost(S[i]->S[j])
i.e. D[i, j] + S[i+1] != T[j+1]
INS: Cost(S[:i+1]->T[:j]) + Cost(T[:j+1]->T[:j])
i.e. D[i+1,j] + 1
DEL: Cost(S[:i]->T[:j+1]) + Cost(S[:i+1]->S[:i]) 
i.e. D[i,j+1] + 1

    Source string S has length m, with index i
    Target string T has length n, with index j

    Output two alignment vectors: i2j (length m) and j2i (length n)
    # function LevenshteinDistance(char s[1..m], char t[1..n]):
    # for all i and j, d[i,j] will hold the Levenshtein distance between
    # the first i characters of s and the first j characters of t
    # note that d has (m+1)*(n+1) values
    # set each element in d to zero
    ring rang
      - r i n g
    - 0 0 0 0 0
    r 0 0 0 0 0
    a 0 0 0 0 0
    n 0 0 0 0 0
    g 0 0 0 0 0

    # source prefixes can be transformed into empty string by
    # dropping all characters
    # d[i, 0] := i
    ring rang
      - r i n g
    - 0 0 0 0 0
    r 1 0 0 0 0
    a 2 0 0 0 0
    n 3 0 0 0 0
    g 4 0 0 0 0

    # target prefixes can be reached from empty source prefix
    # by inserting every character
    # d[0, j] := j
      - r i n g
    - 0 1 2 3 4
    r 1 0 0 0 0
    a 2 0 0 0 0
    n 3 0 0 0 0
    g 4 0 0 0 0

'''
import numpy
cimport numpy as np
from .compat import unicode_
from murmurhash.mrmr cimport hash32


def align(S, T):
    cdef int m = len(S)
    cdef int n = len(T)
    cdef np.ndarray matrix = numpy.zeros((m+1, n+1), dtype='int32')
    cdef np.ndarray i2j = numpy.zeros((m,), dtype='i')
    cdef np.ndarray j2i = numpy.zeros((n,), dtype='i')

    cdef np.ndarray S_arr = _convert_sequence(S)
    cdef np.ndarray T_arr = _convert_sequence(T)

    fill_matrix(<int*>matrix.data,
        <const int*>S_arr.data, m, <const int*>T_arr.data, n)
    fill_i2j(i2j, matrix)
    fill_j2i(j2i, matrix)
    return matrix[-1,-1], i2j, j2i, matrix

def _convert_sequence(seq):
    if isinstance(seq, numpy.ndarray):
        return numpy.ascontiguousarray(seq, dtype='i')
    cdef np.ndarray output = numpy.zeros((len(seq),), dtype='i')
    cdef bytes item_bytes
    for i, item in enumerate(seq):
        if isinstance(item, unicode):
            item_bytes = item.encode('utf8')
        else:
            item_bytes = item
        output[i] = hash32(<void*><char*>item_bytes, len(item_bytes), 0)
    return output


cdef void fill_matrix(int* D, 
        const int* S, int m, const int* T, int n) nogil:
    m1 = m+1
    n1 = n+1
    for i in range(m1*n1):
        D[i] = 0
 
    for i in range(m1):
        D[i*n1] = i
 
    for j in range(n1):
        D[j] = j
 
    cdef int sub_cost, ins_cost, del_cost
    for j in range(n):
        for i in range(m):
            i_j = i*n1 + j
            i1_j1 = (i+1)*n1 + j+1
            i1_j = (i+1)*n1 + j
            i_j1 = i*n1 + j+1
            if S[i] != T[j]:
                sub_cost = D[i_j] + 1
            else:
                sub_cost = D[i_j]
            del_cost = D[i_j1] + 1
            ins_cost = D[i1_j] + 1
            best = min(min(sub_cost, ins_cost), del_cost)
            D[i1_j1] = best


cdef void fill_i2j(np.ndarray i2j, np.ndarray D) except *:
    j = D.shape[1]-2
    cdef int i = D.shape[0]-2
    while i >= 0:
        while D[i+1, j] < D[i+1, j+1]:
            j -= 1
        if D[i, j+1] < D[i+1, j+1]:
            i2j[i] = -1
        else:
            i2j[i] = j
            j -= 1
        i -= 1

cdef void fill_j2i(np.ndarray j2i, np.ndarray D) except *:
    i = D.shape[0]-2
    cdef int j = D.shape[1]-2
    while j >= 0:
        while D[i, j+1] < D[i+1, j+1]:
            i -= 1
        if D[i+1, j] < D[i+1, j+1]:
            j2i[j] = -1
        else:
            j2i[j] = i
            i -= 1
        j -= 1