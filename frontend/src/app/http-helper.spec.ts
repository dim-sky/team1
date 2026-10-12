import { TestBed } from '@angular/core/testing';
import { HttpHelper } from './http-helper';

describe('HttpHelper', () => {
  let service: HttpHelper;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(HttpHelper);
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });
});
