use std::f64::consts::TAU;

#[derive(Clone)]
pub struct Rng {
    s: [u64; 4],
}

pub fn mix64(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    z ^ (z >> 31)
}

pub fn mix_all(parts: &[u64]) -> u64 {
    parts
        .iter()
        .fold(0x6a09_e667_f3bc_c908, |acc, part| mix64(acc ^ mix64(*part)))
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        let mut z = seed;
        let mut next = || {
            z = z.wrapping_add(0x9e37_79b9_7f4a_7c15);
            mix64(z)
        };
        Rng {
            s: [next(), next(), next(), next()],
        }
    }

    pub fn from_parts(parts: &[u64]) -> Self {
        Rng::new(mix_all(parts))
    }

    pub fn next_u64(&mut self) -> u64 {
        let result = self.s[1].wrapping_mul(5).rotate_left(7).wrapping_mul(9);
        let t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = self.s[3].rotate_left(45);
        result
    }

    pub fn f64(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    pub fn below(&mut self, n: u64) -> u64 {
        if n == 0 {
            return 0;
        }
        ((u128::from(self.next_u64()) * u128::from(n)) >> 64) as u64
    }

    pub fn below_usize(&mut self, n: usize) -> usize {
        self.below(n as u64) as usize
    }

    pub fn range(&mut self, lo: u64, hi_inclusive: u64) -> u64 {
        lo + self.below(hi_inclusive.saturating_sub(lo).saturating_add(1))
    }

    pub fn chance(&mut self, p: f64) -> bool {
        self.f64() < p
    }

    pub fn exp(&mut self, mean: f64) -> f64 {
        -mean * (1.0 - self.f64()).ln()
    }

    pub fn normal(&mut self) -> f64 {
        let u1 = 1.0 - self.f64();
        let u2 = self.f64();
        (-2.0 * u1.ln()).sqrt() * (TAU * u2).cos()
    }

    pub fn log_normal(&mut self, median: f64, sigma: f64) -> f64 {
        median * (sigma * self.normal()).exp()
    }

    pub fn log_uniform(&mut self, lo: f64, hi: f64) -> f64 {
        (lo.ln() + self.f64() * (hi.ln() - lo.ln())).exp()
    }

    pub fn pick<'x, T>(&mut self, items: &'x [T]) -> &'x T {
        &items[self.below_usize(items.len())]
    }

    pub fn fill_bytes(&mut self, out: &mut [u8]) {
        let (chunks, rest) = out.as_chunks_mut::<8>();
        for chunk in chunks {
            *chunk = self.next_u64().to_le_bytes();
        }
        if !rest.is_empty() {
            let bytes = self.next_u64().to_le_bytes();
            rest.copy_from_slice(&bytes[..rest.len()]);
        }
    }
}

pub struct Zipf {
    cdf: Box<[f64]>,
}

impl Zipf {
    pub fn new(n: usize, exponent: f64) -> Self {
        let mut acc = 0.0;
        let mut cdf = Vec::with_capacity(n);
        for rank in 1..=n {
            acc += 1.0 / (rank as f64).powf(exponent);
            cdf.push(acc);
        }
        for value in &mut cdf {
            *value /= acc;
        }
        Zipf {
            cdf: cdf.into_boxed_slice(),
        }
    }

    pub fn sample(&self, rng: &mut Rng) -> usize {
        let u = rng.f64();
        self.cdf
            .partition_point(|p| *p < u)
            .min(self.cdf.len().saturating_sub(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deterministic_stream() {
        let mut a = Rng::from_parts(&[1, 2, 3]);
        let mut b = Rng::from_parts(&[1, 2, 3]);
        let mut c = Rng::from_parts(&[1, 2, 4]);
        let xs: Vec<u64> = (0..8).map(|_| a.next_u64()).collect();
        let ys: Vec<u64> = (0..8).map(|_| b.next_u64()).collect();
        let zs: Vec<u64> = (0..8).map(|_| c.next_u64()).collect();
        assert_eq!(xs, ys);
        assert_ne!(xs, zs);
    }

    #[test]
    fn below_is_bounded_and_covers() {
        let mut rng = Rng::new(7);
        let mut seen = [0u32; 10];
        for _ in 0..10_000 {
            seen[rng.below_usize(10)] += 1;
        }
        assert!(seen.iter().all(|c| *c > 800));
    }

    #[test]
    fn zipf_rank_one_dominates() {
        let zipf = Zipf::new(1000, 1.0);
        let mut rng = Rng::new(3);
        let mut first = 0;
        let mut last_half = 0;
        for _ in 0..100_000 {
            let r = zipf.sample(&mut rng);
            if r == 0 {
                first += 1;
            } else if r >= 500 {
                last_half += 1;
            }
        }
        let p_first = first as f64 / 100_000.0;
        assert!((p_first - 0.1336).abs() < 0.01, "{p_first}");
        assert!(last_half > 5000 && last_half < 12000, "{last_half}");
    }

    #[test]
    fn exp_mean() {
        let mut rng = Rng::new(9);
        let n = 200_000;
        let sum: f64 = (0..n).map(|_| rng.exp(2.0)).sum();
        assert!((sum / n as f64 - 2.0).abs() < 0.03);
    }
}
